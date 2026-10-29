import SwiftUI

struct MigrationOverallProgress: View {
    let fraction: Double

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("总体进度（估算）".localized)
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .accessibilityLabel("总体进度".localized)
        }
        .help("总体进度包含准备、扫描、复制、磁盘写入、各轮校验、切换及收尾，按阶段估算；全部完成后才达到 100%。".localized)
    }
}

/// Each step belongs to the directory named above it, not the grouped task bar.
struct MigrationDirectorySteps: View {
    let snapshot: DataTransferProgress.Snapshot
    private var stages: [String] {
        ["准备".localized, "扫描".localized, "复制".localized,
         "校验".localized, "切换".localized, "收尾".localized]
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(stages.indices, id: \.self) { index in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(index == snapshot.directoryStep ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 3)
                    Text(stages[index])
                        .font(.system(size: 10, weight: index == snapshot.directoryStep ? .semibold : .regular))
                        .foregroundStyle(index == snapshot.directoryStep ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == snapshot.directoryStep ? .isSelected : [])
            }
        }
    }
}

@MainActor
struct MigrationTaskToolbarButton: View {
    @ObservedObject private var center = MigrationTaskCenter.shared

    var body: some View {
        Button {
            center.detailID = nil
            center.showsList.toggle()
        } label: {
            HStack(spacing: 6) {
                MigrationTaskToolbarIcon(active: center.hasUnfinishedJobs, attention: center.hasAttention)
                Text("任务中心".localized)
                    .font(.system(size: 13))
                if center.unfinishedCount > 0 {
                    Text("\(center.unfinishedCount)").font(.caption).monospacedDigit()
                }
            }
            .font(.system(size: 16))
            .frame(minWidth: 32, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(center.hasUnfinishedJobs ? Color.blue : (center.hasAttention ? Color.orange : Color.secondary))
        .help("任务中心".localized)
        .accessibilityLabel("任务中心".localized)
        .popover(isPresented: $center.showsList, arrowEdge: .bottom) {
            MigrationTaskList()
        }
    }
}

private struct MigrationTaskToolbarIcon: View {
    let active: Bool
    let attention: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: attention ? "exclamationmark" : "list.bullet")
            .font(.system(size: 12))
            .frame(width: 26, height: 26)
            .overlay {
                if active {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1.3, dash: [3, 3]))
                            .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) * 60))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

private struct MigrationTaskListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
struct MigrationTaskList: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var center: MigrationTaskCenter
    @State private var selection: Set<UUID> = []
    @State private var contentHeight: CGFloat = 90

    init(center: MigrationTaskCenter? = nil) {
        self.center = center ?? .shared
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务中心".localized).font(.headline)
                Spacer()
                Button(selection.count == center.jobs.count ? "取消全选".localized : "全选".localized) {
                    selection = selection.count == center.jobs.count ? [] : Set(center.jobs.map(\.id))
                }
                .disabled(center.jobs.isEmpty)
                Button("关闭".localized) { center.showsList = false }
            }
            .padding(10)
            Divider()
            if center.jobs.isEmpty {
                Text("暂无迁移任务".localized)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(center.jobs.reversed())) { job in
                            MigrationTaskRow(job: job, center: center, selected: Binding(
                                get: { selection.contains(job.id) },
                                set: { value in
                                    if value { selection.insert(job.id) } else { selection.remove(job.id) }
                                }))
                        }
                    }
                    .padding(10)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MigrationTaskListHeightKey.self, value: geometry.size.height)
                    })
                }
                .frame(height: min(contentHeight, 300))
                .onPreferenceChange(MigrationTaskListHeightKey.self) { contentHeight = $0 }
            }
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("暂停".localized) { center.pause(selection) }
                    Button("继续".localized) { center.resume(selection) }
                    Button("取消任务".localized) { center.cancel(selection) }
                }
                .disabled(selection.isEmpty)
                Spacer(minLength: 0)
                Button("清空已完成".localized) { center.clearCompleted() }
                    .disabled(!center.jobs.contains { $0.status == .completed })
                    .help("只清空已完成的任务记录，不删除文件".localized)
            }
            .padding(10)
        }
        .onChange(of: center.jobs.map(\.id)) { ids in
            selection.formIntersection(Set(ids))
        }
        .controlSize(.small)
        .frame(width: 420)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
    }
}

@MainActor
private struct MigrationTaskRow: View {
    @Environment(\.locale) private var locale
    @ObservedObject var job: MigrationJob
    @ObservedObject var center: MigrationTaskCenter
    @Binding var selected: Bool

    private var appIconURL: URL? {
        guard job.category == .apps || job.category == .appData else { return nil }
        return job.resources.paths.sorted().map { URL(fileURLWithPath: $0) }
            .first { $0.pathExtension.lowercased() == "app" }
    }

    private var fallbackIcon: String {
        switch job.category {
        case .apps: return "app.fill"
        case .appData: return "externaldrive.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .directories: return "folder.fill"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(alignment: .center, spacing: 10) {
                Button {
                    selected.toggle()
                } label: {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Color.blue : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择任务".localized)
                .accessibilityValue(selected ? "已选择".localized : "未选择".localized)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if let appIconURL {
                            AppIconView(url: appIconURL, size: 20)
                        } else {
                            Image(systemName: fallbackIcon)
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                        }
                        Button {
                            center.showsList = false
                            center.detailID = job.id
                        } label: {
                            Text(verbatim: job.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help(job.title + " — " + "查看任务详情".localized)
                        Spacer(minLength: 8)
                        Text(verbatim: job.stateTitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        ProgressView(value: job.fraction)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("总体进度".localized)
                        Text(job.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    HStack {
                        if let startedAt = job.startedAt {
                            Text("开始".localized + "：" + startedAt.formatted(.dateTime.hour().minute().second().locale(locale)))
                                .help(startedAt.formatted(Date.FormatStyle(date: .numeric, time: .standard).locale(locale)))
                        } else {
                            Text("尚未开始".localized)
                        }
                        Spacer(minLength: 4)
                        Text("处理时间".localized + "：" + taskDuration(job.elapsed))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    Button {
                        center.showsList = false
                        center.detailID = job.id
                    } label: {
                        Image(systemName: job.status == .attention ? "exclamationmark.circle.fill" : "chevron.right")
                            .font(.system(size: 16))
                            .foregroundStyle(job.status == .attention ? Color.orange : Color.secondary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看任务详情".localized)
                    if !job.status.isFinished {
                        let paused = job.control.snapshot().pauseRequested
                        Button {
                            if paused { center.resume([job.id]) } else { center.pause([job.id]) }
                        } label: {
                            Image(systemName: paused ? "play.fill" : "pause.fill").frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(paused ? "继续".localized : "暂停".localized)
                    } else {
                        Button {
                            center.removeFinished([job.id])
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help("移除任务记录，不删除文件".localized)
                        .accessibilityLabel("移除任务记录".localized)
                    }
                }
            }
            .padding(10)
            .background(job.status == .attention ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

@MainActor
struct MigrationTaskDetail: View {
    @State private var showsAppRecovery = false
    @State private var showsDataRecovery = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var job: MigrationJob
    @ObservedObject private var center: MigrationTaskCenter

    init(job: MigrationJob, center: MigrationTaskCenter? = nil) {
        self.job = job
        self.center = center ?? .shared
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            if job.status.isFinished {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: job.title).font(AppDialogTypography.title)
                    Label(job.stateTitle, systemImage: job.status == .attention ? "exclamationmark.circle.fill" : (job.status == .incomplete ? "archivebox" : (job.status == .cancelled ? "xmark.circle" : "checkmark.circle")))
                        .foregroundStyle(job.status == .attention ? Color.orange : Color.primary)
                    MigrationOverallProgress(fraction: job.fraction)
                    ScrollView {
                        Text(verbatim: job.message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("处理时间".localized + "：" + taskDuration(job.elapsed)).font(AppDialogTypography.body).foregroundStyle(.secondary)
                    HStack {
                        Button("任务列表".localized) { center.detailID = nil; center.showsList = true }
                        if job.status == .attention {
                            Button("处理异常".localized) {
                                if job.category == .apps { showsAppRecovery = true }
                                else if job.recoveryAction == nil { showsDataRecovery = true }
                                else { center.recoveryJobID = job.id }
                            }
                        }
                        Spacer()
                        Button("关闭".localized) { center.detailID = nil }
                    }
                }
                .padding(24)
                .frame(width: 460, height: 450)
                .appDialogTypography()
                .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white,
                            in: RoundedRectangle(cornerRadius: 16))
            } else {
                DataDirProgressContent(title: job.title, snapshot: job.progress.snapshot(),
                    overallProgress: job.fraction, actions: AnyView(actions))
            }
        }
        .sheet(isPresented: $showsAppRecovery) {
            AppMigrationTaskRecoveryView(job: job)
        }
        .sheet(isPresented: $showsDataRecovery) {
            DataMigrationTaskRecoveryView(job: job)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if job.control.snapshot().pauseRequested || job.control.snapshot().cancelled {
                Text(verbatim: job.stateTitle).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消任务".localized) { center.cancel([job.id]) }
                    .disabled(job.control.snapshot().cancelled)
                let paused = job.control.snapshot().pauseRequested
                Button(paused ? "继续".localized : "暂停".localized) {
                    if paused { center.resume([job.id]) } else { center.pause([job.id]) }
                }
                .disabled(job.control.snapshot().cancelled)
                Spacer()
                Button("加入后台".localized) { center.detailID = nil }
            }
        }
        .font(.system(size: 12))
    }
}

private func taskDuration(_ seconds: TimeInterval) -> String {
    let value = Int(max(0, seconds))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}
