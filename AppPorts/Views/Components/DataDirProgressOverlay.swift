import SwiftUI

/// The timeline refreshes only this small surface, including during worker
/// syscalls that cannot report a percentage. It never advances work counters.
struct DataDirProgressOverlay: View {
    let title: String
    let progress: DataTransferProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            DataDirProgressContent(title: title, snapshot: progress.snapshot())
        }
    }
}

struct DataDirProgressContent: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let snapshot: DataTransferProgress.Snapshot
    var overallProgress: Double? = nil
    var actions: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 34, alignment: .topLeading)

            if let overallProgress {
                MigrationOverallProgress(fraction: overallProgress)
            }

            HStack {
                Text((URL(fileURLWithPath: snapshot.directoryPath).pathExtension.lowercased() == "app"
                    ? "当前应用".localized : "当前目录".localized)
                    + "：" + URL(fileURLWithPath: snapshot.directoryPath).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(snapshot.directoryPath)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(snapshot.directoryPath.isEmpty ? 0 : 1)
                    .accessibilityHidden(snapshot.directoryPath.isEmpty)
                if snapshot.unitCount > 1 {
                    Text("\(snapshot.unitIndex + 1) / \(snapshot.unitCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 18)

            MigrationDirectorySteps(snapshot: snapshot)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(verbatim: snapshot.stepTitle.isEmpty ? snapshot.presentationStage.title : snapshot.stepTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if let fraction = snapshot.fraction {
                                Text(fraction, format: .percent.precision(.fractionLength(0)))
                                    .font(.system(size: 13, weight: .medium))
                                    .monospacedDigit()
                            }
                        }
        
                        if let fraction = snapshot.fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .accessibilityLabel(snapshot.presentationStage.title)
                        }
        
                        Text(verbatim: snapshot.detail.isEmpty ? snapshot.presentationStage.explanation : snapshot.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
        
                    statistics
        
                    if !snapshot.currentFile.isEmpty {
                        Text(verbatim: snapshot.currentFile)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(snapshot.currentFile)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
        
                    if snapshot.isWaitingForActivity {
                        Text(String(format: "已 %@ 未收到新的文件进度，正在等待当前步骤返回。".localized, duration(snapshot.activityAge)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text(String(format: "已用时 %@".localized, duration(snapshot.elapsed)))
                Spacer(minLength: 8)
                Text(String(format: "此阶段 %@".localized, duration(snapshot.stageElapsed)))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if let actions {
                Divider()
                actions
            }
        }
        .padding(24)
        .frame(width: 460, height: 450)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white,
                            in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statistics: some View {
        if snapshot.stage == .copying {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.totalBytes > 0
                    ? String(format: "已复制 %@ / %@".localized, bytes(snapshot.copiedBytes), bytes(snapshot.totalBytes))
                    : String(format: "已复制 %@".localized, bytes(snapshot.copiedBytes)))
                Spacer(minLength: 8)
                if let rate = snapshot.visibleCopyRate, rate > 0 {
                    Text(String(format: "%@/秒".localized, bytes(Int64(min(rate, Double(Int64.max / 2))))))
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
        } else if snapshot.completedItems > 0 || snapshot.readBytes > 0 {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "当前步骤已处理 %lld 项".localized, Int64(snapshot.completedItems)))
                Spacer(minLength: 8)
                if snapshot.readBytes > 0 {
                    Text(String(format: "已读取 %@".localized, bytes(snapshot.readBytes)))
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
        }
    }

    private func bytes(_ value: Int64) -> String {
        LocalizedByteCountFormatter.string(fromByteCount: value)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
