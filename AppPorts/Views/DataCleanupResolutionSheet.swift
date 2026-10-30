import SwiftUI

struct DataCleanupResolutionSheet: View {
    let transfers: [DataTransferRecord]
    var currentDataPaths: [UUID: String] = [:]
    var pendingCleanups: [ContainerCleanupRecord] = []
    var preservedMaterials: [DataTransferMaterial] = []
    var remountInterventions: [String] = []
    let onRetry: (UUID?) -> Void
    let onChanged: () -> Void
    let onPermissions: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var confirmKeep = false
    @State private var keepRequest: DataTransferRecord?
    @State private var updated: [UUID: DataTransferRecord.CleanupDisposition] = [:]

    var body: some View {
        let visibleTransfers = transfers.filter { $0.retainedCopyRemovedAt == nil }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("处理异常".localized).font(AppDialogTypography.title)
                Spacer()
                Button("检查权限".localized) { dismiss(); onPermissions() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if visibleTransfers.isEmpty && pendingCleanups.isEmpty && preservedMaterials.isEmpty && remountInterventions.isEmpty {
                        Text("未找到待处理的迁移记录，可能已由后台完成收尾。请关闭窗口后刷新应用列表。".localized)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(visibleTransfers) { transfer in
                        transferRow(transfer)
                        if transfer.id != visibleTransfers.last?.id {
                            Divider()
                        }
                    }
                    ForEach(Array(remountInterventions.enumerated()), id: \.offset) { _, reason in
                        Text(verbatim: reason)
                            .font(AppDialogTypography.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    ForEach(pendingCleanups) { cleanup in
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: cleanup.mountRecord.appName).font(AppDialogTypography.title)
                            Text("数据操作尚未完成，现有文件已保留。请退出关联应用，连接并解锁外置盘后重试。".localized)
                                .foregroundStyle(.secondary)
                            retainedPath(cleanup.localPath)
                            if let staging = cleanup.restoreStagingPath { retainedPath(staging) }
                            retainedPath(cleanup.mountRecord.externalRootPath)
                        }
                    }
                    ForEach(preservedMaterials) { material in
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: material.appName).font(AppDialogTypography.title)
                            Text(verbatim: material.reason).font(AppDialogTypography.body).textSelection(.enabled)
                            retainedPath(material.originalPath)
                            ForEach(Array(Set(material.paths).subtracting([material.originalPath])).sorted(), id: \.self) { path in
                                retainedPath(path)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                Text(verbatim: errorMessage).font(AppDialogTypography.body).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if !pendingCleanups.isEmpty || !remountInterventions.isEmpty || preservedMaterials.contains(where: { $0.recoveryRecord != nil }) {
                    Button("重试所有待处理项".localized) { dismiss(); onRetry(nil) }
                }
                Spacer()
                Button("完成".localized) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .appDialogTypography()
        .frame(width: 620, height: 460)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .alert("保留副本并结束清理？".localized, isPresented: $confirmKeep) {
            Button("取消".localized, role: .cancel) { keepRequest = nil }
            Button("保留副本".localized) {
                if let transfer = keepRequest { decide(.keep, for: transfer) }
                keepRequest = nil
            }
        } message: {
            Text("所有剩余旧文件会保留在原位置，继续占用空间，不会合并或覆盖正在使用的数据。软件将停止自动清理和异常提醒，你仍可在这里打开副本或重新尝试清理。".localized)
        }
    }

    private func retainedPath(_ path: String) -> some View {
        Text(verbatim: path)
            .font(AppDialogTypography.body)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .contextMenu {
                Button("复制路径".localized) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
    }

    private func transferRow(_ transfer: DataTransferRecord) -> some View {
        let disposition = updated[transfer.id] ?? transfer.cleanupDisposition
        let needsAdministrator = DataCleanupResolution.requiresAdministrator(transfer)
        let administratorMessage = "旧副本由管理员（root）拥有，需要授权后才能清理。当前数据未受影响。".localized
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: transfer.appName).font(AppDialogTypography.title)
                Spacer()
                if disposition == .keep {
                    Text("已保留旧副本".localized).foregroundStyle(.secondary)
                } else if disposition == .deferred {
                    Text("已暂停自动处理".localized).foregroundStyle(.secondary)
                }
            }
            if let path = currentDataPaths[transfer.id] {
                Text(String(format: "当前数据：%@".localized, path)).font(AppDialogTypography.body).textSelection(.enabled)
            } else {
                Text(verbatim: transfer.originalPath).font(AppDialogTypography.body).textSelection(.enabled)
            }
            if needsAdministrator, disposition != .keep, transfer.recoverableReason?.contains(administratorMessage) != true {
                Text(verbatim: administratorMessage).font(AppDialogTypography.body)
            }
            if disposition != .keep, let reason = transfer.recoverableReason {
                Text(verbatim: reason).font(AppDialogTypography.body).textSelection(.enabled)
            }
            if disposition != .keep {
                Text(transfer.isDataSwitchComplete
                    ? "数据已切换，旧副本尚未清理完。重试会重新检查，不会强制删除有差异的文件。".localized
                    : "数据操作尚未完成，现有文件已保留。请退出关联应用，连接并解锁外置盘后重试。".localized)
                    .font(AppDialogTypography.body).foregroundStyle(.secondary)
            }
            if let path = transfer.backupPath {
                Text(String(format: "保留的旧副本：%@".localized, path))
                    .font(AppDialogTypography.body).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(needsAdministrator ? "授权清理旧副本".localized
                        : disposition == .keep ? "重新尝试清理".localized : "重试".localized) {
                        dismiss(); onRetry(transfer.id)
                    }
                    if transfer.isDataSwitchComplete {
                        Button("打开旧副本".localized) { openRetained(transfer) }
                    }
                }
                HStack {
                    if transfer.isDataSwitchComplete, disposition != .keep {
                        Button("保留副本并结束清理".localized) { keepRequest = transfer; confirmKeep = true }
                    }
                    if disposition == nil {
                        Button("稍后处理".localized) { decide(.deferred, for: transfer) }
                    }
                }
            }
            .controlSize(.regular)
        }
    }

    private func decide(_ disposition: DataTransferRecord.CleanupDisposition, for transfer: DataTransferRecord) {
        busy = true
        errorMessage = nil
        Task {
            do {
                // The sheet snapshot remains unchanged after a local choice.
                // Pass its latest disposition to the store's compare-and-set.
                let expected: DataTransferRecord = {
                    var record = transfer
                    if let value = updated[transfer.id] { record.cleanupDisposition = value }
                    return record
                }()
                try await Task.detached(priority: .utility) {
                    try await DataCleanupResolution.decide(disposition, expected: expected)
                }.value
                updated[transfer.id] = disposition
                onChanged()
            } catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }

    private func openRetained(_ transfer: DataTransferRecord) {
        busy = true
        errorMessage = nil
        Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    try await DataCleanupResolution.retainedURL(for: transfer)
                }.value
                if !NSWorkspace.shared.open(url) {
                    errorMessage = "无法打开旧副本，请确认磁盘已连接且有访问权限。".localized
                }
            } catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}
