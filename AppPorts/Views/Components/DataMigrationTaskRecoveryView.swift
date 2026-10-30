import SwiftUI

/// Historical jobs and cleanup warnings have no executable migration callback.
/// Show current ledger facts and use maintenance for any explicit recovery.
@MainActor
struct DataMigrationTaskRecoveryView: View {
    let job: MigrationJob
    @Environment(\.dismiss) private var dismiss
    @State private var transfers: [DataTransferRecord] = []
    @State private var pendingCleanups: [ContainerCleanupRecord] = []
    @State private var preservedMaterials: [DataTransferMaterial] = []
    @State private var remountInterventions: [String] = []
    @State private var currentDataPaths: [UUID: String] = [:]
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView().frame(width: 460, height: 180)
            } else if errorMessage == nil, !transfers.isEmpty || !pendingCleanups.isEmpty || !preservedMaterials.isEmpty || !remountInterventions.isEmpty {
                DataCleanupResolutionSheet(transfers: transfers, currentDataPaths: currentDataPaths,
                    pendingCleanups: pendingCleanups, preservedMaterials: preservedMaterials,
                    remountInterventions: remountInterventions,
                    onRetry: { operationID in
                        MigrationTaskCenter.shared.submit(title: "正在继续处理".localized,
                            category: job.category,
                            resources: MigrationResources(paths: [], keys: ["all-file-operations"]),
                            operation: { _ in
                                let warnings = await OperationMaintenance.shared.runManagedDataOperations(retryOperationID: operationID)
                                try Task.checkCancellation()
                                return warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
                            })
                    }, onChanged: { Task { await loadRecords() } }, onPermissions: {
                        if let url = LaunchReadinessChecker.Item.Action.fullDiskAccess.settingsURLs.first {
                            NSWorkspace.shared.open(url)
                        }
                    })
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("处理异常".localized).font(AppDialogTypography.title)
                    Text(verbatim: errorMessage
                        ?? "未找到待处理的迁移记录，可能已由后台完成收尾。请关闭窗口后刷新应用列表。".localized)
                        .textSelection(.enabled)
                    HStack {
                        Button("刷新".localized) { Task { await loadRecords() } }
                        Button(job.category.title) {
                            dismiss()
                            MigrationTaskCenter.shared.recoveryJobID = job.id
                        }
                        Spacer()
                        Button("关闭".localized) { dismiss() }
                    }
                }
                .padding(20)
                .frame(width: 460)
            }
        }
        .appDialogTypography()
        .task { await loadRecords() }
    }

    private func loadRecords() async {
        loading = true
        errorMessage = nil
        do {
            let (inspection, paths) = try await Task.detached(priority: .utility) {
                let inspection = try ContainerMountStore.shared.recordsForInspection()
                return (inspection, DataCleanupResolution.currentDataPaths(for: inspection.transfers))
            }.value
            guard !Task.isCancelled else { return }
            if let error = inspection.validationError { throw error }
            transfers = inspection.transfers.filter { $0.retainedCopyRemovedAt == nil }
            currentDataPaths = paths
            pendingCleanups = inspection.cleanups
            preservedMaterials = inspection.preservedMaterials
            remountInterventions = inspection.remountInterventions.values.sorted()
        } catch { errorMessage = error.localizedDescription }
        loading = false
    }
}
