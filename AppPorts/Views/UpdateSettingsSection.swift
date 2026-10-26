import SwiftUI

struct UpdateSettingsSection: View {
    @AppStorage(UpdateChannel.defaultsKey) private var channel = UpdateChannel.official.rawValue
    @State private var isChecking = false
    @State private var result: UpdateCheckResult?
    @ObservedObject private var updater = AppUpdateController.shared

    private var hasPendingDownload: Bool { updater.isPreparing || updater.prepared != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("更新".localized).font(.headline)
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在检查更新…".localized)
                }
                Button("检查更新".localized) { isChecking = true }
                    .disabled(isChecking || hasPendingDownload)
            }
            Picker("更新".localized, selection: $channel) {
                Text("GitHub".localized).tag(UpdateChannel.github.rawValue)
                Text("国内下载".localized).tag(UpdateChannel.official.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isChecking || hasPendingDownload)

            if isChecking {
                Text("正在检查更新…".localized).foregroundStyle(.secondary)
            } else if let result {
                Text(statusText(for: result))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .available(update) = result, !hasPendingDownload {
                    AppUpdateActions(update: update)
                }
            }
            if hasPendingDownload {
                GitHubUpdateControls()
            }
        }
        .task(id: isChecking) {
            guard isChecking else { return }
            let selectedChannel = UpdateChannel(rawValue: channel) ?? .official
            let checked = await UpdateChecker.shared.checkForUpdatesResult(channel: selectedChannel)
            guard !Task.isCancelled else { return }
            result = checked
            isChecking = false
        }
        .onChange(of: channel) { _ in result = nil }
        .onDisappear { isChecking = false }
    }

    private func statusText(for result: UpdateCheckResult) -> String {
        switch result {
        case .available(let update): return "发现新版本".localized + " · " + update.version
        case .upToDate: return "当前已是最新版本。".localized
        case .failed: return "无法检查更新，请稍后重试。".localized
        }
    }
}
