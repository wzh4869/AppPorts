import AppKit
import Combine
import Foundation

@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()

    @Published private(set) var isPreparing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var prepared: PreparedAppUpdate?
    @Published private(set) var errorMessage: String?
    @Published private(set) var version: String?
    private var task: Task<Void, Never>?
    private var installToken: UUID?

    var allowsTermination: Bool {
        guard let installToken else { return false }
        return AppOperationState.shared.isOnlyOperation(installToken)
    }

    func download(_ update: AppUpdateInfo) {
        guard !isPreparing, installToken == nil else { return }
        discardPrepared()
        version = update.version
        errorMessage = nil
        isPreparing = true
        progress = 0
        let destination = Bundle.main.bundleURL
        task = Task {
            do {
                let candidate = try await Task.detached(priority: .utility) {
                    try await GitHubUpdatePackage().prepare(update: update, destination: destination) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }.valueWithCancellation()
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: candidate.workspace)
                } else {
                    prepared = candidate
                }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isPreparing = false
            task = nil
        }
    }

    func cancel() {
        guard installToken == nil else { return }
        if isPreparing { task?.cancel() }
        else { discardPrepared(); errorMessage = nil; version = nil }
    }

    func finishBeforeTerminating(_ reply: @escaping @MainActor () -> Void) -> Bool {
        guard let task else { discardPrepared(); return false }
        task.cancel()
        Task { await task.value; reply() }
        return true
    }

    func install() {
        guard let prepared, !isPreparing, installToken == nil else { return }
        let operations = AppOperationState.shared
        guard let token = operations.begin() else {
            errorMessage = "还有任务尚未结束".localized
            return
        }
        let lock = OperationLock()
        guard lock.tryAcquire() else {
            operations.finish(token)
            errorMessage = lock.admissionFailureReason ?? "其他程序正在处理磁盘，请稍后重试。".localized
            return
        }
        defer { lock.release() }
        do {
            let helper = try AppUpdateInstaller.launch(prepared)
            installToken = token
            NSApp.terminate(nil)
            // terminate() only returns if some lifecycle participant cancels Quit.
            if helper.isRunning { helper.terminate() }
            installToken = nil
            operations.finish(token)
            errorMessage = "还有任务尚未结束".localized
        } catch {
            installToken = nil
            operations.finish(token)
            errorMessage = error.localizedDescription
        }
    }

    private func discardPrepared() {
        if let prepared { try? FileManager.default.removeItem(at: prepared.workspace) }
        prepared = nil
    }
}

private extension Task where Failure == Error {
    func valueWithCancellation() async throws -> Success {
        try await withTaskCancellationHandler(operation: { try await value }, onCancel: { cancel() })
    }
}
