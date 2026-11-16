import AppKit
import SwiftUI

struct UpdateSettingsSection: View {
    var isEmbedded = false
    @State private var isChecking = false
    @State private var result: UpdateCheckResult?
    @State private var availableUpdate: AppUpdateInfo?
    @ObservedObject private var updater = AppUpdateController.shared

    private var hasPendingDownload: Bool { updater.isPreparing || updater.prepared != nil }

    private var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(format: "Version %@".localized, "\(value) (\(build))")
    }

    var body: some View {
        Group {
            if isEmbedded { content }
            else { content.modifier(AppSettingsPanelStyle()) }
        }
        .task(id: isChecking) {
            guard isChecking else { return }
            let checked = await UpdateChecker.shared.checkForUpdatesResult()
            guard !Task.isCancelled else { return }
            result = checked
            isChecking = false
            if case let .available(update) = checked { availableUpdate = update }
        }
        .modifier(AppUpdatePresentation(update: $availableUpdate))
        .onDisappear { isChecking = false }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSettingsStyle.sectionGap) {
            HStack(spacing: AppSettingsStyle.sectionGap) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: AppSettingsStyle.applicationIconSize, height: AppSettingsStyle.applicationIconSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppSettingsStyle.relatedGap) {
                    Text(verbatim: "AppPorts").font(AppSettingsStyle.sectionFont)
                    Text(version).font(AppSettingsStyle.secondaryFont).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !hasPendingDownload {
                    Button("检查更新".localized) { isChecking = true }
                        .disabled(isChecking)
                        .fixedSize()
                }
            }
            .font(AppSettingsStyle.bodyFont)
            .controlSize(AppSettingsStyle.controlSize)
            .buttonStyle(.bordered)

            Text(verbatim: Bundle.main.bundleURL.path)
                .font(AppSettingsStyle.secondaryFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help("当前运行的 AppPorts".localized)

            HStack(spacing: AppSettingsStyle.rowGap) {
                Link("官网".localized, destination: URL(string: "https://appports.shimoko.com/")!)
                Link("文档".localized, destination: URL(string: "https://docs-appports.shimoko.com/")!)
                Button("关于".localized) {
                    AboutWindowController.shared.present()
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .font(AppSettingsStyle.bodyFont)
            .controlSize(AppSettingsStyle.controlSize)

            if hasPendingDownload {
                HStack {
                    Spacer(minLength: 0)
                    GitHubUpdateControls(showsStatus: false)
                }
                .buttonStyle(.bordered)
            }

            if isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检查更新…".localized).foregroundStyle(.secondary)
                }
            } else if hasPendingDownload || updater.errorMessage != nil {
                GitHubUpdateStatus()
            } else if let result {
                Text(statusText(for: result))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }

    private func statusText(for result: UpdateCheckResult) -> String {
        switch result {
        case .available(let update): return "发现新版本".localized + " · " + update.version
        case .upToDate: return "当前已是最新版本。".localized
        case .failed: return "无法检查更新，请稍后重试。".localized
        }
    }
}
