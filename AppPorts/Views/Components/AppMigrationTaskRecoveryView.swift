import SwiftUI
import AppKit

/// Recovery reads the durable transaction, rather than relying on an error callback.
@MainActor
struct AppMigrationTaskRecoveryView: View {
    let job: MigrationJob
    @Environment(\.dismiss) private var dismiss
    @State private var records: [AppTransferRecord] = []
    @State private var message = ""
    @State private var loading = true
    @State private var forcedOperation: ForcedRecoveryRequest?
    @State private var recordIssues: [AppTransferRecordIssue] = []

    private struct ForcedRecoveryRequest: Identifiable {
        let id: UUID
        let appName: String
        let restore: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("处理应用迁移异常".localized).font(AppDialogTypography.title)
            Text(verbatim: job.message).font(AppDialogTypography.body).textSelection(.enabled)
            if loading {
                ProgressView()
            } else {
                if !message.isEmpty {
                    Text(verbatim: message).font(AppDialogTypography.body).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: record.appName).font(AppDialogTypography.body)
                                ForEach(record.pendingTasks) { task in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(verbatim: task.message)
                                            if let path = task.path {
                                                Text(verbatim: path).foregroundStyle(.secondary).textSelection(.enabled)
                                            }
                                        }
                                        Spacer()
                                        if let path = task.path {
                                            Button("在访达中查看".localized) {
                                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                            }
                                        }
                                    }
                                    .font(AppDialogTypography.body)
                                }
                                Button("重试处理".localized) { retry(record) }
                                HStack {
                                    Button("忽略错误强制回迁".localized) {
                                        forcedOperation = .init(id: record.operationID, appName: record.appName, restore: true)
                                    }
                                    Button("忽略错误结束任务".localized) {
                                        forcedOperation = .init(id: record.operationID, appName: record.appName, restore: false)
                                    }
                                }
                                .font(AppDialogTypography.body)
                            }
                        }
                        ForEach(recordIssues) { issue in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: issue.appName).font(AppDialogTypography.body)
                                Text(verbatim: issue.message).font(AppDialogTypography.body)
                                if let id = UUID(uuidString: issue.url.deletingPathExtension().lastPathComponent) {
                                    Button("忽略错误结束任务".localized) {
                                        forcedOperation = .init(id: id, appName: issue.appName, restore: false)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            HStack {
                Spacer()
                Button("关闭".localized) { dismiss() }
            }
        }
        .padding(20)
        .appDialogTypography()
        .frame(width: 480)
        .task { await loadRecords() }
        .alert(item: $forcedOperation) { request in
            Alert(
                title: Text(request.restore ? "忽略错误强制回迁".localized : "忽略错误结束任务".localized),
                message: Text(request.restore
                    ? "将外置盘上的应用复制到本地，不进行内容校验。复制成功后替换本地链接，保留外置盘原文件和已有本地副本；原迁移记录归档为未完成。".localized
                    : "只将这条迁移记录强制归档为未完成，解除其占用，不删除任何文件；下次迁移可以重新开始。".localized),
                primaryButton: .destructive(Text("继续".localized)) { forceRecover(operationID: request.id, appName: request.appName, restore: request.restore) },
                secondaryButton: .cancel(Text("取消".localized)))
        }
    }

    private func loadRecords() async {
        let paths = job.resources.paths
        let result = await Task.detached(priority: .utility) { () -> ([AppTransferRecord], [AppTransferRecordIssue], String) in
            do {
                let inventory = try AppMigrationService().pendingTransferInspection()
                let matches = inventory.records.filter {
                    paths.contains($0.sourcePath) || paths.contains($0.destinationPath)
                }
                let issues = inventory.issues.map(\.message).joined(separator: "\n")
                let relatedIssues = inventory.issues.filter { !paths.isDisjoint(with: $0.knownPaths) }
                return (matches, relatedIssues, issues)
            } catch { return ([], [], error.localizedDescription) }
        }.value
        guard !Task.isCancelled else { return }
        records = result.0
        recordIssues = result.1
        message = result.2
        if records.isEmpty && recordIssues.isEmpty && message.isEmpty {
            message = "未找到待处理的迁移记录，可能已由后台完成收尾。请关闭窗口后刷新应用列表。".localized
        }
        loading = false
    }

    private func forceRecover(operationID: UUID, appName: String, restore: Bool) {
        let originalJobID = job.id
        MigrationTaskCenter.shared.submit(
            title: (restore ? "强制回迁".localized : "归档未完成任务".localized) + " · " + appName,
            category: .apps, resources: job.resources,
            operation: { progress in
                let message = try await AppMigrationService().recoverTransferIgnoringErrors(
                    operationID: operationID, restore: restore, progress: progress)
                await MainActor.run {
                    MigrationTaskCenter.shared.markArchivedIncomplete(originalJobID, message: message)
                }
                // The override action can finish, but an unverified restored app remains a warning.
                return restore ? message : nil
            })
        dismiss()
    }

    private func retry(_ record: AppTransferRecord) {
        MigrationTaskCenter.shared.submit(
            title: "重试处理".localized + " · " + record.appName,
            category: .apps, resources: job.resources,
            operation: { progress in
                progress.setDirectory(URL(fileURLWithPath: record.sourcePath))
                let result = try await AppMigrationService().retryTransfer(operationID: record.operationID,
                    progressHandler: { progress.update($0) })
                return result.pendingMessage
            })
        dismiss()
    }
}
