import Combine
import CoreFoundation
import Foundation

enum AppStoreExternalInstallPreference: Equatable {
    case disabled
    case enabled(volumeUUID: UUID, name: String)
    case unknown

    // App Store derives its enabled checkbox from this dictionary and clears
    // it when disabled. Read through cfprefsd so a return from Settings is fresh.
    static func read(domain: String = "com.apple.appstored") -> Self {
        let domain = domain as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return .unknown }
        let value = CFPreferencesCopyValue("PreferredVolume" as CFString, domain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let value else { return .disabled }
        guard let dictionary = value as? [String: String] else { return .unknown }
        if dictionary.isEmpty { return .disabled }
        guard let identifier = dictionary["volumeID"], let uuid = UUID(uuidString: identifier) else { return .unknown }
        return .enabled(volumeUUID: uuid, name: dictionary["name"] ?? identifier)
    }
}

@MainActor
final class AppStoreExternalInstallSettings: ObservableObject {
    enum State: Equatable {
        case ready
        case notConfigured
        case differentVolume(name: String)
        case unavailable
        case unknown
        case notSelected
        case unsupported
    }

    struct Probe {
        var preference: () -> AppStoreExternalInstallPreference
        var volumeUUID: (URL) -> UUID?

        static let live = Probe(preference: { AppStoreExternalInstallPreference.read() }, volumeUUID: { url in
            guard let identifier = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return nil }
            return UUID(uuidString: identifier)
        })
    }

    static let shared = AppStoreExternalInstallSettings()
    static let dismissGuidanceKey = "AppStoreExternalInstallGuidanceDismissed"
    @Published private(set) var state: State = .notSelected
    @Published private(set) var destinationURL: URL?
    private let defaults: UserDefaults
    private let probe: Probe
    private let isSupported: Bool

    init(defaults: UserDefaults = .standard, probe: Probe = .live,
         isSupported: Bool = AppMigrationService.isMASExternalInstallSupported) {
        self.defaults = defaults
        self.probe = probe
        self.isSupported = isSupported
    }

    var shouldPresentGuidance: Bool {
        guard !defaults.bool(forKey: Self.dismissGuidanceKey) else { return false }
        switch state {
        case .notConfigured, .differentVolume: return true
        default: return false
        }
    }

    func refresh(for externalDriveURL: URL?) {
        destinationURL = externalDriveURL.map { AppMigrationService.masApplicationsURL(for: $0) }
        guard isSupported else { state = .unsupported; return }
        guard let externalDriveURL else { state = .notSelected; return }
        switch probe.preference() {
        case .disabled: state = .notConfigured
        case .unknown: state = .unknown
        case .enabled(let selectedUUID, let name):
            guard let targetUUID = probe.volumeUUID(AppMigrationService.volumeRoot(for: externalDriveURL)) else {
                state = .unavailable
                return
            }
            state = selectedUUID == targetUUID ? .ready : .differentVolume(name: name)
        }
    }

    func makeGuidanceRequest(onOpenAppStore: @escaping () -> Void, onCheck: @escaping () -> Void) -> WarningSheetRequest {
        let name = destinationURL?.deletingLastPathComponent().lastPathComponent ?? ""
        var request = WarningSheetRequest(
            title: "App Store 应用外部安装".localized,
            icon: "info.circle.fill",
            tint: .blue,
            intro: String(format: "In App Store Settings, enable “Download and install large apps to a separate disk”, then select “%@”. This applies to newly downloaded apps larger than 1 GB.".localized(fallbackLanguage: "en"), name),
            bullets: [WarningBullet("gearshape", "Settings: You can complete this later in AppPorts Settings, even after choosing “Don’t remind me again”.".localized(fallbackLanguage: "en"))],
            cancelTitle: "Don’t remind me again".localized(fallbackLanguage: "en"),
            onCancel: { self.defaults.set(true, forKey: Self.dismissGuidanceKey) },
            actions: [
                WarningAction("打开 App Store 设置".localized, handler: onOpenAppStore),
                WarningAction("我已设置".localized, style: .preferred, handler: onCheck)
            ]
        )
        if case .differentVolume(let selectedName) = state {
            request.detail = String(format: "App Store currently uses “%@”. Select “%@” to match AppPorts.".localized(fallbackLanguage: "en"), selectedName, name)
        }
        return request
    }
}
