import AppKit
import SwiftUI

struct UpdateSettingsSection: View {
    @State private var isChecking = false
    @State private var result: UpdateCheckResult?
    @State private var showsUpdate = false
    @ObservedObject private var updater = AppUpdateController.shared

    private var hasPendingDownload: Bool { updater.isPreparing || updater.prepared != nil }

    private var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(format: "Version %@".localized, "\(value) (\(build))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "AppPorts").font(.largeTitle.bold())
                    Text("macOS 应用迁移工具".localized)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(version).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Divider()

            HStack(spacing: 10) {
                Link("官网".localized, destination: URL(string: "https://appports.shimoko.com/")!)
                Link("文档".localized, destination: URL(string: "https://docs-appports.shimoko.com/")!)
                Button("关于".localized) {
                    AboutWindowController.shared.present()
                }
                Button("检查更新".localized) { isChecking = true }
                    .disabled(isChecking || hasPendingDownload)
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)

            if isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检查更新…".localized).foregroundStyle(.secondary)
                }
            } else if let result {
                Text(statusText(for: result))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hasPendingDownload {
                GitHubUpdateControls()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .task(id: isChecking) {
            guard isChecking else { return }
            let checked = await UpdateChecker.shared.checkForUpdatesResult()
            guard !Task.isCancelled else { return }
            result = checked
            isChecking = false
            if case .available = checked { showsUpdate = true }
        }
        .sheet(isPresented: $showsUpdate) {
            if case let .available(update) = result {
                AppUpdateSheet(update: update)
            }
        }
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
