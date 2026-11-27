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
    @State private var showingAll = false

    private var title: String { showingAll ? "全部待处理项".localized : job.displayTitle }

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView().frame(width: 460, height: 180)
            } else if errorMessage == nil, !transfers.isEmpty || !pendingCleanups.isEmpty || !preservedMaterials.isEmpty || !remountInterventions.isEmpty {
                DataCleanupResolutionSheet(transfers: transfers, currentDataPaths: currentDataPaths,
                    pendingCleanups: pendingCleanups, preservedMaterials: preservedMaterials,
                    remountInterventions: remountInterventions,
                    title: title, onShowAll: showingAll ? nil : { showingAll = true },
                    onRetryAll: showingAll ? { submitRetry(nil) } : nil,
                    onRetry: { submitRetry($0) }, onChanged: { Task { await loadRecords() } }, onPermissions: {
                        FullDiskAccessGuide.shared.openSettings()
                    })
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: title).font(AppDialogTypography.title)
                    Text(verbatim: errorMessage
                        ?? (showingAll ? "未找到待处理的迁移记录，可能已由后台完成收尾。请关闭窗口后刷新应用列表。".localized
                           : "没有可确认属于此任务的待处理记录。".localized))
                        .textSelection(.enabled)
                    HStack {
                        Button("刷新".localized) { Task { await loadRecords() } }
                        if !showingAll { Button("查看全部待处理项".localized) { showingAll = true } }
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
        .task(id: showingAll) { await loadRecords() }
    }

    private func loadRecords() async {
        loading = true
        errorMessage = nil
        do {
            let global = showingAll
            let scope = DataTaskRecoveryScope(jobID: job.id, resources: job.resources, startedAt: job.startedAt, elapsed: job.elapsed)
            let (inspection, selected, material, paths) = try await Task.detached(priority: .utility) {
                let inventory = try ContainerMountStore.shared.recordsForInspection()
                if let error = inventory.validationError { throw error }
                let ids = global ? [] : scope.operationIDs(transfers: inventory.transfers, materials: inventory.preservedMaterials)
                let selected = inventory.transfers.filter { $0.retainedCopyRemovedAt == nil && (global || ids.contains($0.id)) }
                let material = inventory.preservedMaterials.filter { global || ids.contains($0.id) }
                return (inventory, selected, material, DataCleanupResolution.currentDataPaths(for: selected))
            }.value
            guard !Task.isCancelled, showingAll == global else { return }
            transfers = selected
            preservedMaterials = material
            currentDataPaths = paths
            pendingCleanups = global ? inspection.cleanups : []
            remountInterventions = global ? inspection.remountInterventions.values.sorted() : []
        } catch { errorMessage = error.localizedDescription }
        loading = false
    }

    private func submitRetry(_ operationID: UUID?) {
        guard operationID != nil || showingAll else { return }
        MigrationTaskCenter.shared.submit(title: "继续处理".localized, category: job.category,
            resources: MigrationResources(paths: [], keys: ["all-file-operations"], dataOperationIDs: Set([operationID].compactMap { $0 })),
            operation: { _ in
                let warnings = await OperationMaintenance.shared.runManagedDataOperations(retryOperationID: operationID)
                try Task.checkCancellation()
                return warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
            })
    }

}
