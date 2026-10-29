import Foundation

/// Refresh only after the task owns its resources; display snapshots never authorize execution.
struct AppDataMigrationPreparation: Sendable {
    let app: AppItem
    let externalRoot: URL?
    let splitMode: Bool
    let containerIdentifier: String

    enum Failure: LocalizedError {
        case changed
        var errorDescription: String? { "目录状态已变化，请重新选择后再迁移。".localized }
    }

    func refresh(_ item: DataDirItem, progress: DataTransferProgress) async throws -> DataDirItem {
        let control = MigrationExecution.control
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try await control?.checkpointAsync()
            try Task.checkCancellation()
            progress.begin(.preparing)
            guard LaunchReadinessChecker.fullDiskAccessState() == .granted else {
                throw DataOperationSafety.Failure.accessDenied(item.path.path)
            }
            let scanner = DataDirScanner(partialWeChatMigrationEnabled: splitMode,
                                         weChatContainerIdentifier: containerIdentifier)
            let result = await scanner.scanLibraryDirsWithDiagnostics(for: app, externalRootURL: externalRoot)
            try await control?.checkpointAsync()
            try Task.checkCancellation()
            let grouped = WeChatAccountMigrationService.groupedItems(result.items, splitMode: splitMode,
                                                                      containerIdentifier: containerIdentifier)
            let fresh = try Self.refreshedItem(item, result: .init(items: grouped,
                readIssues: result.readIssues, identityIssue: result.identityIssue)) {
                measureDataDirectorySize(for: $0, useCache: false)
            }
            try await control?.checkpointAsync()
            try Task.checkCancellation()
            return fresh
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func refreshedItem(_ original: DataDirItem, result: DataDirScanResult,
                              measure: (DataDirItem) -> DirectorySizeResult) throws -> DataDirItem {
        guard result.identityIssue == nil,
              var fresh = result.items.first(where: { $0.path.standardizedFileURL == original.path.standardizedFileURL }),
              fresh.isMigratable, fresh.status == DataDirStatus.local,
              Set(fresh.weChatSplitMembers.map { $0.path.standardizedFileURL.path })
                == Set(original.weChatSplitMembers.map { $0.path.standardizedFileURL.path }) else { throw Failure.changed }
        let measured = measure(fresh)
        try Task.checkCancellation()
        guard measured.isComplete else { throw DataOperationSafety.Failure.accessDenied(fresh.path.path) }
        fresh.applySize(measured)
        return fresh
    }
}
