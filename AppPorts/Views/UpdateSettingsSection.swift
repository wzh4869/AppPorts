import AppKit
import SwiftUI

struct UpdateSettingsSection: View {
    var isEmbedded = false
    @State private var isChecking = false
    @State private var result: UpdateCheckResult?
    @State private var availableUpdate: AppUpdateInfo?
    @State private var showBoundaryConsensus = false
    @ObservedObject private var updater = AppUpdateController.shared
    @ObservedObject private var languageManager = LanguageManager.shared

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
        .sheet(isPresented: $showBoundaryConsensus) {
            BoundaryConsensusSheet()
        }
        .modifier(AppUpdatePresentationDismissal {
            showBoundaryConsensus = false
        })
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

            settingsLinksRow
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

    @ViewBuilder
    private var settingsLinksRow: some View {
        if #available(macOS 13.0, *) {
            SettingsWrapRowLayout(horizontalSpacing: AppSettingsStyle.rowGap, verticalSpacing: AppSettingsStyle.rowGap) {
                settingsLinkControls
            }
        } else {
            HStack(spacing: AppSettingsStyle.rowGap) {
                settingsLinkControls
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var settingsLinkControls: some View {
        Link("官网".localized, destination: URL(string: "https://appports.shimoko.com/")!)
            .fixedSize()
        Link("文档".localized, destination: DocumentationLink.homeURL())
            .fixedSize()
        Button("边界与共识".localized) {
            showBoundaryConsensus = true
        }
        .fixedSize()
        Button("关于".localized) {
            AboutWindowController.shared.present()
        }
        .fixedSize()
    }

    private func statusText(for result: UpdateCheckResult) -> String {
        switch result {
        case .available(let update): return "发现新版本".localized + " · " + update.version
        case .upToDate: return "当前已是最新版本。".localized
        case .failed: return "无法检查更新，请稍后重试。".localized
        }
    }
}

@available(macOS 13.0, *)
private struct SettingsWrapRowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + horizontalSpacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                if rowWidth > 0 { rowWidth += horizontalSpacing }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: cursorX, y: cursorY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            cursorX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
