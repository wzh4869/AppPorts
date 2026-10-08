import SwiftUI

struct AppSearchExclusionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessing = false
    @State private var isLoading = true
    @State private var report: AppSearchExclusionReport?
    let load: @MainActor () async -> AppSearchExclusionReport
    let process: @MainActor () async -> AppSearchExclusionReport

    var body: some View {
        AppSearchExclusionPanel(report: report, isProcessing: isProcessing, isLoading: isLoading,
            close: { dismiss() }, process: {
                guard !isLoading, !isProcessing else { return }
                isProcessing = true
                Task { @MainActor in
                    report = await process()
                    isProcessing = false
                }
            })
            .interactiveDismissDisabled(isProcessing)
            .task {
                isLoading = true
                let current = await load()
                guard !Task.isCancelled else { return }
                report = current
                isLoading = false
            }
    }
}

/// Read-only presentation is shared by the live sheet and rendered previews.
struct AppSearchExclusionPanel: View {
    let report: AppSearchExclusionReport?
    let isProcessing: Bool
    var isLoading = false
    let close: () -> Void
    let process: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Text("普通独立应用会移入专用应用库，本地入口仍可使用。外盘文档和照片的搜索不受影响。".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading || isProcessing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(isLoading ? "正在检查…".localized : "正在处理外盘应用…".localized)
                }
                .font(.callout)
            } else if let error = report?.operationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let report, report.entries.isEmpty {
                Label("没有可处理的外盘应用。".localized, systemImage: "tray")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                ExclusionColumn(completed: true, entries: report?.completed ?? [],
                    hasResults: report != nil, isProcessing: isProcessing || isLoading,
                    allCompleted: false)
                ExclusionColumn(completed: false, entries: report?.incomplete ?? [],
                    hasResults: report != nil, isProcessing: isProcessing || isLoading,
                    allCompleted: report?.operationError == nil && !(report?.entries.isEmpty ?? true))
            }
            .frame(height: 340)

            footer
        }
        .padding(24)
        .frame(width: 820)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("排除外盘应用索引".localized).font(.title2.bold())
                Text("避免 Spotlight 同时索引本地入口和外盘应用，导致搜索结果重复。".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let report {
                Text(String(format: "共 %d 个应用".localized, report.entries.count))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report == nil
                 ? "App Store、iOS 应用和套件目录暂不处理，以保留安装更新路径和文档搜索。".localized
                 : "存储位置已排除后，Spotlight 仍可能需要时间更新结果。".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("关闭".localized, action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isProcessing)
                Button("自动处理".localized, action: process)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isProcessing || isLoading || report?.entries.contains(where: { $0.outcome != .completed && $0.outcome != .unsupported }) != true)
            }
        }
    }
}

private struct ExclusionColumn: View {
    let completed: Bool
    let entries: [AppSearchExclusionReport.Entry]
    let hasResults: Bool
    let isProcessing: Bool
    let allCompleted: Bool

    private var tint: Color { completed ? .green : .orange }
    private var title: String { completed ? "已完成".localized : "未完成".localized }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title).font(.headline)
                Text(entries.count.formatted())
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(tint.opacity(0.12), in: Capsule())
                Spacer()
            }
            .padding(14)
            .accessibilityElement(children: .combine)
            Divider().padding(.horizontal, 14)
            if entries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(entries) { entry in
                            ExclusionResultCard(entry: entry)
                        }
                    }
                    .padding(10)
                }
                .accessibilityLabel(title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: hasResults && !completed && allCompleted ? "checkmark.seal" : "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(emptyTitle).font(.callout.weight(.medium))
        }
        .multilineTextAlignment(.center)
        .padding(20)
    }

    private var emptyTitle: String {
        if isProcessing { return "正在整理结果…".localized }
        if !hasResults { return "等待处理".localized }
        if completed { return "暂无已完成应用".localized }
        return allCompleted ? "全部处理完成".localized : "暂无未完成应用".localized
    }
}

private struct ExclusionResultCard: View {
    let entry: AppSearchExclusionReport.Entry

    private var tint: Color {
        switch entry.outcome {
        case .completed: return .green
        case .failed: return .red
        case .pending, .unsupported, .dockWarning: return .orange
        }
    }

    private var status: String {
        switch entry.outcome {
        case .completed: return "已排除索引".localized
        case .pending: return "等待处理".localized
        case .unsupported: return "暂不支持".localized
        case .failed: return "处理失败".localized
        case .dockWarning: return "Dock 待同步".localized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AppIconView(url: entry.iconURL, size: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.displayName)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Label(status, systemImage: entry.outcome.isCompleted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(tint)
                }
                Spacer(minLength: 0)
            }
            if !entry.outcome.isCompleted {
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}
