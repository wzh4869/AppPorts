import Foundation

/// Presentation stages describe actual work, independently of the durable
/// transaction state. A copied-byte total never means the operation is done.
enum DataTransferStage: Equatable, Sendable {
    case waiting, preparing, scanning, copying, synchronizing, verifying, switching, cleaning, recovering

    var title: String {
        switch self {
        case .waiting: return "正在等待其他操作结束".localized
        case .preparing: return "正在准备数据操作".localized
        case .scanning: return "正在扫描源文件".localized
        case .copying: return "正在复制文件".localized
        case .synchronizing: return "正在写入磁盘".localized
        case .verifying: return "正在校验文件".localized
        case .switching: return "正在切换本地入口...".localized
        case .cleaning: return "正在清理旧副本...".localized
        case .recovering: return "正在自动恢复数据入口...".localized
        }
    }

    var explanation: String {
        switch self {
        case .waiting: return "其他磁盘操作结束后会自动继续。".localized
        case .preparing: return "正在检查目录、访问权限和目标存储。".localized
        case .scanning: return "正在读取文件内容和属性，建立校验清单；文件较多时需要一些时间。".localized
        case .copying: return "正在把源目录的文件复制到新位置；完成后会检查复制结果，再切换数据入口。".localized
        case .synchronizing: return "正在将文件内容和属性写入存储设备，等待系统确认。".localized
        case .verifying: return "正在核对文件内容和属性，确保数据完整；大目录可能需要较长时间。".localized
        case .switching: return "正在连接新的数据位置并保存迁移记录。".localized
        case .cleaning: return "正在核验并移除旧副本，文件较多时清理可能较慢。".localized
        case .recovering: return "正在检查实际数据位置并恢复可用入口。".localized
        }
    }
}

/// Describe why a verification pass is needed instead of presenting every
/// readback as the same anonymous verification step.
enum DataTransferVerification: Sendable {
    case copiedData, sourceUnchanged, beforeSwitch, activeData, retainedCopy, appBeforeSwitch, replacement

    var title: String {
        switch self {
        case .appBeforeSwitch: return "正在复核新位置的应用".localized
        case .replacement: return "正在检查已有目标应用".localized
        case .copiedData: return "正在检查复制结果".localized
        case .sourceUnchanged: return "正在确认源目录未变化".localized
        case .beforeSwitch: return "正在复核即将使用的数据".localized
        case .activeData: return "正在检查当前使用的数据".localized
        case .retainedCopy: return "正在检查待清理的副本".localized
        }
    }

    var explanation: String {
        switch self {
        case .appBeforeSwitch: return "切换应用位置前，再次核对新位置的应用文件和属性，随后检查原有签名是否仍然有效。".localized
        case .replacement: return "正在核对即将替换的目标应用，确认它与记录一致，避免覆盖操作期间出现的新内容。".localized
        case .copiedData: return "正在读取新位置的文件，与源文件清单核对，检查是否完整复制。".localized
        case .sourceUnchanged: return "正在检查复制期间源文件是否发生变化，确认可以安全切换到新位置。".localized
        case .beforeSwitch: return "复制结果已检查；切换入口前，再确认即将使用的文件完整且未被改动。".localized
        case .activeData: return "清理旧副本前，先核对当前使用的数据，确认新位置的文件仍然完整。".localized
        case .retainedCopy: return "正在核对副本中的剩余文件，只有符合清理条件的文件才会删除；发现差异会保留。".localized
        }
    }
}

/// Workers update a small, locked snapshot. Only the overlay polls it, so a
/// synchronous scan or thousands of copy callbacks never flood the main actor.
/// This object is per operation; it must not be reused for the next directory.
final class DataTransferProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        var stage: DataTransferStage = .waiting
        var detail = ""
        var stepTitle = ""
        var directoryPath = ""
        var currentFile = ""
        var completedItems = 0
        var expectedItems = 0
        var readBytes: Int64 = 0
        var copiedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var copyBytesPerSecond: Double?
        // Weighted whole-operation progress. A scan or signature check before
        // copying cannot jump into the post-copy verification part of the bar.
        var unitFraction: Double = 0
        var unitIndex = 0
        var unitCount = 1
        var overallFraction: Double {
            (Double(unitIndex) + unitFraction) / Double(max(1, unitCount))
        }
        var hasStartedCopy = false
        var tracksEntrySwitchBoundaries = false
        var hasEnteredEntrySwitch = false
        var hasEnteredCleanup = false
        /// Low-level mount operations and protective notifications do not mean
        /// the effective entry is being replaced. Keep their execution stage,
        /// but present the directory workflow's actual commit boundary.
        var presentationStage: DataTransferStage {
            if hasEnteredCleanup { return .cleaning }
            if hasEnteredEntrySwitch { return .switching }
            if stage == .switching, tracksEntrySwitchBoundaries {
                return hasStartedCopy ? .verifying : .preparing
            }
            return stage
        }
        var directoryStep: Int {
            switch presentationStage {
            case .waiting, .preparing, .recovering: return 0
            case .scanning: return 1
            case .copying, .synchronizing: return hasStartedCopy ? 2 : 0
            case .verifying: return hasStartedCopy ? 3 : 0
            case .switching: return hasStartedCopy || hasEnteredEntrySwitch ? 4 : 0
            case .cleaning: return hasStartedCopy ? 5 : 0
            }
        }
        var startedAt: TimeInterval
        var stageStartedAt: TimeInterval
        var lastActivityAt: TimeInterval
        var sampledAt: TimeInterval

        var elapsed: TimeInterval { max(0, sampledAt - startedAt) }
        var stageElapsed: TimeInterval { max(0, sampledAt - stageStartedAt) }
        var activityAge: TimeInterval { max(0, sampledAt - lastActivityAt) }
        var fraction: Double? {
            guard stage == .copying, totalBytes > 0 else { return nil }
            return min(1, max(0, Double(copiedBytes) / Double(totalBytes)))
        }

        /// A changing timer is not evidence of filesystem progress.
        var isWaitingForActivity: Bool { activityAge >= 15 }
        var visibleCopyRate: Double? {
            guard stage == .copying, activityAge < 3 else { return nil }
            return copyBytesPerSecond
        }
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var state: Snapshot
    private var rateSampleTime: TimeInterval
    private var rateSampleBytes: Int64 = 0
    private var unitPaths: [String] = []
    private var verificationStart: Double = 0.60
    private var verificationWeight: Double = 0.12

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        let now = clock()
        state = Snapshot(startedAt: now, stageStartedAt: now, lastActivityAt: now, sampledAt: now)
        rateSampleTime = now
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var result = state
        result.sampledAt = clock()
        return result
    }

    func track<Result>(_ operation: (@escaping FileCopier.ProgressHandler) async throws -> Result) async rethrows -> Result {
        defer { MigrationExecution.control?.setCriticalSection(false) }
        return try await DataTransferSession.$progress.withValue(self) {
            try await DataTransferSession.run {
                try await operation { self.update($0) }
            }
        }
    }

    func configureUnits(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        unitPaths = urls.map { $0.standardizedFileURL.path }
        state.unitCount = max(1, unitPaths.count)
        state.unitIndex = 0
        state.unitFraction = 0
    }

    func setDirectory(_ url: URL, onlyIfUnset: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let path = url.standardizedFileURL.path
        if !onlyIfUnset || state.directoryPath.isEmpty {
            state.directoryPath = path
            if let index = unitPaths.firstIndex(of: path), index > state.unitIndex {
                state.unitIndex = index
                state.unitFraction = 0
                state.hasStartedCopy = false
                state.tracksEntrySwitchBoundaries = false
                state.hasEnteredEntrySwitch = false
                state.hasEnteredCleanup = false
            }
        }
    }

    func verify(_ purpose: DataTransferVerification) {
        lock.lock(); defer { lock.unlock() }
        transition(to: .verifying, detail: purpose.explanation, title: purpose.title, at: clock())
        switch purpose {
        case .copiedData: verificationStart = 0.60; verificationWeight = 0.12
        case .sourceUnchanged: verificationStart = 0.72; verificationWeight = 0.08
        case .beforeSwitch, .appBeforeSwitch, .replacement: verificationStart = 0.80; verificationWeight = 0.06
        case .activeData: verificationStart = 0.90; verificationWeight = 0.04
        case .retainedCopy: verificationStart = 0.94; verificationWeight = 0.05
        }
        if state.hasStartedCopy { state.unitFraction = max(state.unitFraction, verificationStart) }
    }

    /// A resumed durable transaction can already have verified data even though
    /// this observer never copied it. This changes presentation only.
    func observeResumedCopy(cleanup: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.tracksEntrySwitchBoundaries = true
        state.hasStartedCopy = true
        if cleanup { state.hasEnteredCleanup = true }
        state.unitFraction = max(state.unitFraction, cleanup ? 0.94 : 0.60)
    }

    /// Declare directory presentation before private preparation mounts. This
    /// does not reset a predecessor's cleanup or alter execution protection.
    func observeDirectoryWorkflow() {
        lock.lock(); defer { lock.unlock() }
        state.tracksEntrySwitchBoundaries = true
    }

    /// Presentation only: callers report this after final proof, immediately
    /// before committing the effective entry. Original critical-section events
    /// and durable transaction phases retain their existing ordering.
    func observeEntrySwitch() {
        lock.lock(); defer { lock.unlock() }
        state.tracksEntrySwitchBoundaries = true
        state.hasEnteredEntrySwitch = true
        state.unitFraction = max(state.unitFraction, 0.88)
    }

    /// A predecessor may have been cleaned using this same observer and path.
    /// Reset presentation at a new copy, never at an internal preparation stage.
    /// App-bundle callers keep their existing switching events as the boundary.
    func observeNewCopy(tracksEntrySwitchBoundaries: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.tracksEntrySwitchBoundaries = tracksEntrySwitchBoundaries
        state.hasStartedCopy = false
        state.hasEnteredEntrySwitch = false
        state.hasEnteredCleanup = false
        state.unitFraction = 0
        state.copiedBytes = 0
        state.totalBytes = 0
        rateSampleBytes = 0
        transition(to: .preparing, detail: "", at: clock())
    }

    func begin(_ stage: DataTransferStage, detail: String = "", currentFile: String = "", title: String = "") {
        if stage == .switching || stage == .recovering {
            MigrationExecution.control?.setCriticalSection(true)
        } else if stage == .cleaning {
            MigrationExecution.control?.setCriticalSection(false)
        }
        lock.lock(); defer { lock.unlock() }
        transition(to: stage, detail: detail, title: title, at: clock())
        if !currentFile.isEmpty, currentFile != state.currentFile {
            state.currentFile = currentFile
            state.lastActivityAt = clock()
        }
    }

    func update(_ progress: FileCopier.Progress) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let stage = progress.showsByteProgress ? progress.stage : (progress.stage == .copying ? .preparing : progress.stage)
        transition(to: stage, detail: progress.detail, at: now)
        let file = progress.showsByteProgress ? progress.currentFile : ""
        if state.currentFile != file || (stage == .copying && state.copiedBytes != progress.copiedBytes) {
            state.lastActivityAt = now
        }
        state.currentFile = file
        guard stage == .copying else { return }
        let bytes = max(0, progress.copiedBytes)
        if bytes < state.copiedBytes {
            rateSampleTime = now
            rateSampleBytes = bytes
            state.copyBytesPerSecond = nil
        } else if now - rateSampleTime >= 0.5 {
            state.copyBytesPerSecond = Double(bytes - rateSampleBytes) / (now - rateSampleTime)
            rateSampleTime = now
            rateSampleBytes = bytes
        }
        state.copiedBytes = bytes
        state.totalBytes = max(0, progress.totalBytes)
        if state.totalBytes > 0 {
            state.unitFraction = max(state.unitFraction,
                0.20 + 0.35 * min(1, Double(bytes) / Double(state.totalBytes)))
        }
    }

    /// A traversal resets its counters even when several verification passes
    /// run in the same stage. Count work from this pass, not unique user files.
    func startTraversal(at root: URL, expectedItems: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        state.completedItems = 0
        state.expectedItems = max(0, expectedItems)
        state.readBytes = 0
        state.stageStartedAt = clock()
        state.currentFile = root.lastPathComponent
        state.lastActivityAt = clock()
    }

    func activity(file: String? = nil, bytesRead: Int64 = 0, completedItem: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if let file, !file.isEmpty { state.currentFile = file }
        state.readBytes += max(0, bytesRead)
        if completedItem { state.completedItems += 1 }
        if state.stage == .verifying, state.hasStartedCopy, state.expectedItems > 0 {
            let fraction = min(1, Double(state.completedItems) / Double(state.expectedItems))
            state.unitFraction = max(state.unitFraction, verificationStart + verificationWeight * fraction)
        }
        state.lastActivityAt = clock()
    }

    private func transition(to stage: DataTransferStage, detail: String, title: String = "", at now: TimeInterval) {
        guard stage != state.stage || detail != state.detail || title != state.stepTitle else { return }
        state.stage = stage
        let floor: Double
        switch stage {
        case .waiting: floor = 0
        case .preparing: floor = 0.01
        case .scanning: floor = state.hasStartedCopy ? state.unitFraction : 0.05
        case .copying: state.hasStartedCopy = true; floor = 0.20
        case .synchronizing: floor = state.hasStartedCopy ? 0.55 : 0.03
        case .verifying: floor = state.hasStartedCopy ? 0.60 : 0.03
        case .switching:
            floor = state.hasEnteredEntrySwitch || (!state.tracksEntrySwitchBoundaries && state.hasStartedCopy)
                ? 0.88 : (state.hasStartedCopy ? state.unitFraction : 0.03)
        case .cleaning:
            if state.hasStartedCopy { state.hasEnteredCleanup = true }
            floor = state.hasStartedCopy ? 0.94 : 0.03
        case .recovering: floor = state.unitFraction
        }
        state.unitFraction = max(state.unitFraction, floor)
        state.detail = detail
        state.stepTitle = title
        state.stageStartedAt = now
        state.lastActivityAt = now
        state.currentFile = ""
        state.completedItems = 0
        state.expectedItems = 0
        state.readBytes = 0
        state.copyBytesPerSecond = nil
        rateSampleTime = now
        rateSampleBytes = stage == .copying ? 0 : state.copiedBytes
        if stage == .copying {
            state.copiedBytes = 0
            state.totalBytes = 0
        }
    }
}
