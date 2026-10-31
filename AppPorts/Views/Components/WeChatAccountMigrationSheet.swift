import SwiftUI

struct WeChatAccountMigrationSheet: View {
    let item: DataDirItem
    let containerIdentifier: String
    let onConfirm: (WeChatAccountMigrationService.Mode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: WeChatAccountMigrationService.Mode = .split
    @State private var sizing: WeChatAccountMigrationService.Sizing?
    @State private var errorMessage: String?

    private func sizeRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("微信账号迁移".localized).font(AppDialogTypography.title)
                Spacer()
                Text(item.path.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            }
            Picker("迁移方式".localized, selection: $mode) {
                Text("全部迁移".localized).tag(WeChatAccountMigrationService.Mode.whole)
                Text("拆分迁移".localized).tag(WeChatAccountMigrationService.Mode.split)
            }
            .pickerStyle(.radioGroup)
            if let sizing {
                if mode == .whole {
                    sizeRow("迁移整个账号目录".localized, value: sizing.total.formattedSize)
                    Text("外置盘未连接时，微信可能无法启动。".localized)
                        .font(AppDialogTypography.body).foregroundStyle(.secondary)
                } else {
                    sizeRow("迁移 msg + business".localized, value: sizing.media.formattedSize)
                    sizeRow("本地保留数据库等数据".localized,
                                   value: LocalizedByteCountFormatter.string(fromByteCount: sizing.retainedBytes))
                    Text("仅迁移媒体文件，数据库和配置留在本地。外置盘未连接时的文字消息可用性取决于微信版本。".localized)
                        .font(AppDialogTypography.body).foregroundStyle(.secondary)
                }
                if mode == .whole ? !sizing.total.isComplete : !sizing.isComplete {
                    Text("目录大小未能完整读取，请检查访问权限后重试。".localized)
                        .foregroundStyle(.orange)
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange)
            } else {
                HStack { ProgressView().controlSize(.small); Text("正在计算目录大小…".localized) }
            }
            Text("切换迁移方式前，需要先完整还原。其他微信数据不受此操作影响。".localized)
                .font(AppDialogTypography.body).foregroundStyle(.secondary)
            HStack {
                Button("取消".localized) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("开始迁移".localized) { onConfirm(mode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .whole ? sizing?.total.isComplete != true : sizing?.isComplete != true)
            }
        }
        .padding(24)
        .appDialogTypography()
        .frame(width: 480)
        .task {
            let account = item.path
            let identifier = containerIdentifier
            let worker = Task.detached(priority: .userInitiated) {
                try WeChatAccountMigrationService(containerIdentifier: identifier).measure(account)
            }
            await withTaskCancellationHandler {
                do {
                    let result = try await worker.value
                    guard !Task.isCancelled else { return }
                    sizing = result
                } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            } onCancel: { worker.cancel() }
        }
    }
}
