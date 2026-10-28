import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let appPortsWillInstallUpdate = Notification.Name("AppPorts.willInstallUpdate")
}

@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()

    @Published private(set) var isPreparing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var prepared: PreparedAppUpdate?
    @Published private(set) var errorMessage: String?
    @Published private(set) var version: String?
    private var task: Task<Void, Never>?
    @Published private var installToken: UUID?
    private var installationHelper: Process?
    private var restartTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private let operations: AppOperationState
    private let makeOperationLock: () -> OperationLock
    private let launchInstaller: (PreparedAppUpdate) throws -> Process
    private let requestTermination: @MainActor () async throws -> Void

    init(operationState: AppOperationState? = nil,
         makeOperationLock: @escaping () -> OperationLock = { OperationLock() },
         launchInstaller: @escaping (PreparedAppUpdate) throws -> Process = { try AppUpdateInstaller.launch($0) },
         requestTermination: @escaping @MainActor () async throws -> Void = {
             try await AppUpdateController.requestApplicationTermination()
         }) {
        operations = operationState ?? .shared
        self.makeOperationLock = makeOperationLock
        self.launchInstaller = launchInstaller
        self.requestTermination = requestTermination
    }

    var allowsTermination: Bool {
        guard let installToken else { return false }
        return operations.isOnlyOperation(installToken)
    }

    var isInstalling: Bool { installToken != nil }

    var installationBlocked: Bool {
        if let installToken { return !operations.isOnlyOperation(installToken) }
        return operations.isBusy
    }

    func download(_ update: AppUpdateInfo, channel: UpdateChannel = .github) {
        guard !isPreparing, installToken == nil else { return }
        discardPrepared()
        version = update.version
        errorMessage = nil
        isPreparing = true
        progress = 0
        let destination = Bundle.main.bundleURL
        task = Task {
            do {
                let resolvedUpdate: AppUpdateInfo
                if channel == .official {
                    resolvedUpdate = try await UpdateChecker.shared.domesticUpdate(for: update)
                } else if update.source == .github, update.githubAsset != nil {
                    resolvedUpdate = update
                } else {
                    resolvedUpdate = try await UpdateChecker.shared.githubUpdate(for: update)
                }
                try Task.checkCancellation()
                let candidate = try await Task.detached(priority: .utility) {
                    try await GitHubUpdatePackage().prepare(update: resolvedUpdate, destination: destination) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }.valueWithCancellation()
                if Task.isCancelled {
                    queueCleanup(candidate)
                } else {
                    prepared = candidate
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.shared.logError("应用更新失败", error: error)
                    errorMessage = AppUpdateError.message(for: error)
                }
            }
            isPreparing = false
            task = nil
        }
    }

    func cancel() {
        stopInstallation()
        if isPreparing { task?.cancel() }
        else { discardPrepared(); errorMessage = nil; version = nil }
    }

    func finishBeforeTerminating(_ reply: @escaping @MainActor () -> Void) -> Bool {
        let downloadTask = task
        downloadTask?.cancel()
        discardPrepared()
        guard downloadTask != nil || cleanupTask != nil else { return false }
        Task {
            await downloadTask?.value
            await waitForCleanup()
            reply()
        }
        return true
    }

    func install() {
        guard let prepared else { return }
        install(prepared)
    }

    func install(_ prepared: PreparedAppUpdate) {
        guard !isPreparing, installToken == nil else { return }
        guard let token = operations.begin() else {
            errorMessage = "还有任务尚未结束".localized
            return
        }
        let lock = makeOperationLock()
        guard lock.tryAcquire() else {
            operations.finish(token)
            errorMessage = lock.admissionFailureReason ?? "其他程序正在处理磁盘，请稍后重试。".localized
            return
        }
        defer { lock.release() }
        do {
            installationHelper = try launchInstaller(prepared)
            installToken = token
            errorMessage = nil
            AppLogger.shared.logContext("更新安装 helper 已启动", details: [("version", prepared.version)])
            // AppKit may return while termination is still being processed.
            // The delegate owns a refusal; keep the helper alive until the app exits.
            restartTask = Task { [weak self] in
                guard let self else { return }
                do {
                    AppLogger.shared.logContext("更新安装等待历史清理", details: [])
                    await self.waitForCleanup()
                    AppLogger.shared.logContext("更新安装历史清理已完成", details: [])
                    try Task.checkCancellation()
                    try await self.requestTermination()
                    AppLogger.shared.logContext("更新退出请求已返回，等待进程退出", details: [])
                } catch {
                    if !Task.isCancelled {
                        self.stopInstallation()
                        self.errorMessage = AppUpdateError.message(for: error)
                    }
                }
            }
            if let helper = installationHelper {
                helper.terminationHandler = { [weak self] process in
                    Task { @MainActor in self?.installationHelperExited(process) }
                }
                if !helper.isRunning { installationHelperExited(helper) }
            }
        } catch {
            installToken = nil
            operations.finish(token)
            errorMessage = error.localizedDescription
        }
    }

    private func installationHelperExited(_ helper: Process) {
        guard installationHelper === helper, installToken != nil else { return }
        AppLogger.shared.logContext("更新安装 helper 在应用退出前结束", details: [("status", String(helper.terminationStatus))])
        stopInstallation()
        errorMessage = AppUpdateError.quitBlocked.localizedDescription
    }

    func cancelInstallationForTerminationRefusal() {
        guard isInstalling else { return }
        stopInstallation()
        errorMessage = AppUpdateError.quitBlocked.localizedDescription
    }

    private func stopInstallation() {
        restartTask?.cancel()
        restartTask = nil
        guard let token = installToken else { return }
        installationHelper?.terminationHandler = nil
        if let installationHelper, installationHelper.isRunning {
            installationHelper.terminate()
        }
        queueCleanup(nil, waitingFor: installationHelper)
        installationHelper = nil
        installToken = nil
        operations.finish(token)
    }

    static func dismissSheets(in windows: [NSWindow]) async throws {
        for window in windows {
            guard let sheet = window.attachedSheet else { continue }
            try Task.checkCancellation()
            try await dismissSheets(in: [sheet])
            try await endSheet(sheet, parent: window)
        }
    }

    /// Keep every AppKit access on the main actor, including after sheet dismissal
    /// suspends. An unisolated async callback may resume on the generic executor.
    static func requestApplicationTermination(
        windows: @MainActor () -> [NSWindow] = { NSApp.windows },
        modalWindow: @MainActor () -> NSWindow? = { NSApp.modalWindow },
        terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    ) async throws {
        AppLogger.shared.logContext("更新退出开始关闭弹窗", details: [])
        NotificationCenter.default.post(name: .appPortsWillInstallUpdate, object: nil)
        // SwiftUI owns the presentation bindings. Let it process their dismissal
        // before using AppKit to finish any remaining sheet animations.
        await Task.yield()
        try await dismissSheets(in: windows())
        AppLogger.shared.logContext("更新退出弹窗关闭已完成", details: [])
        try Task.checkCancellation()
        guard modalWindow() == nil else { throw AppUpdateError.quitBlocked }
        AppLogger.shared.logContext("更新请求 AppKit 退出", details: [])
        terminate()
    }

    private static func endSheet(_ sheet: NSWindow, parent: NSWindow) async throws {
        try Task.checkCancellation()
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        // AppKit detaches the sheet after its dismissal animation. Yield to
        // that animation instead of repeatedly ending the same attached sheet.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while parent.attachedSheet === sheet {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppUpdateError.quitBlocked }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func discardPrepared() {
        let candidate = prepared
        prepared = nil
        if let candidate { queueCleanup(candidate) }
    }

    private func queueCleanup(_ candidate: PreparedAppUpdate?, waitingFor helper: Process? = nil) {
        let previous = cleanupTask
        cleanupTask = Task.detached(priority: .utility) {
            await previous?.value
            if let helper, helper.isRunning { helper.waitUntilExit() }
            if let candidate { try? FileManager.default.removeItem(at: candidate.workspace) }
        }
    }

    func waitForCleanup() async {
        await cleanupTask?.value
    }
}

private extension Task where Failure == Error {
    func valueWithCancellation() async throws -> Success {
        try await withTaskCancellationHandler(operation: { try await value }, onCancel: { cancel() })
    }
}
