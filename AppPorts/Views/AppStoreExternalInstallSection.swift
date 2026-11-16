import AppKit
import SwiftUI

@MainActor
struct AppStoreExternalInstallSection: View {
    @ObservedObject var settings: AppStoreExternalInstallSettings

    var body: some View {
        AppSettingsSection(title: "App Store 应用外部安装".localized, headerAccessory: {
            if settings.state == .ready {
                Label {
                    Text("Configured".localized(fallbackLanguage: "en"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppSettingsStyle.success)
                }
                .font(AppSettingsStyle.secondaryFont)
                .fixedSize()
            }
        }) {
            Text(detail)
                .font(AppSettingsStyle.secondaryFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let destination = settings.destinationURL {
                VStack(alignment: .leading, spacing: AppSettingsStyle.relatedGap) {
                    Text("AppPorts can migrate App Store apps of any size, including apps under 1 GB, to:".localized(fallbackLanguage: "en"))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: destination.path)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(AppSettingsStyle.secondaryFont)
            }
            if settings.state != .ready {
                Button("打开 App Store 设置".localized, action: Self.openAppStoreSettings)
            }
        }
    }

    static func openAppStoreSettings() {
        if let url = URL(string: "macappstores://settings") { NSWorkspace.shared.open(url) }
    }

    private var detail: String {
        switch settings.state {
        case .ready:
            return "App Store will also install newly downloaded apps larger than 1 GB on this drive and manage their updates.".localized(fallbackLanguage: "en")
        case .notConfigured:
            return "Not configured. In App Store Settings, enable external installation for apps larger than 1 GB and choose the same external drive as AppPorts.".localized(fallbackLanguage: "en")
        case .differentVolume(let name):
            return String(format: "App Store currently uses “%@”. Choose the same external drive as AppPorts in App Store Settings.".localized(fallbackLanguage: "en"), name)
        case .notSelected:
            return "Choose external storage in AppPorts before configuring App Store external installation.".localized(fallbackLanguage: "en")
        case .unavailable:
            return "Reconnect the selected external drive to check the App Store installation setting.".localized(fallbackLanguage: "en")
        case .unknown, .unsupported:
            return "Could not read the App Store installation setting. Open App Store Settings to check it.".localized(fallbackLanguage: "en")
        }
    }
}
