import SwiftUI

struct APFSVolumePasswordSheet: View {
    let isCreating: Bool
    let onConfirm: (APFSVolumeEncryption.Credentials) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var saveToKeychain = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isCreating ? "设置数据卷密码".localized : "解锁数据卷".localized)
                .font(AppDialogTypography.title)
            Text(isCreating
                 ? "新数据卷独立加密，不会继承外置盘密码。微信拆分迁移的多个数据卷共用本次设置。".localized
                 : "输入迁移时设置的数据卷密码。30 分钟内可复用，正在执行的操作会保持到结束。".localized)
                .font(AppDialogTypography.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("密码".localized, text: $passphrase)
                .focused($passwordFocused)
            if isCreating {
                SecureField("确认密码".localized, text: $confirmation)
            }
            Toggle(isOn: $saveToKeychain) {
                Text("保存到本机钥匙串，连接外置盘后自动解锁".localized)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isCreating && !saveToKeychain {
                Text("请妥善保存密码，遗忘后无法恢复这些数据。".localized)
                    .font(AppDialogTypography.body).foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(AppDialogTypography.body) }
            HStack {
                Button("取消".localized) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(isCreating ? "继续迁移".localized : "解锁并继续".localized) {
                    errorMessage = nil
                    do { try APFSVolumeEncryption.validate(passphrase) }
                    catch { errorMessage = error.localizedDescription; return }
                    guard !isCreating || passphrase == confirmation else {
                        errorMessage = "两次输入的密码不一致。".localized
                        return
                    }
                    let credentials = APFSVolumeEncryption.Credentials(passphrase: passphrase, saveToKeychain: saveToKeychain)
                    isWorking = true
                    Task { @MainActor in
                        defer { isWorking = false }
                        do {
                            try await onConfirm(credentials)
                            passphrase = ""
                            confirmation = ""
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty || (isCreating && confirmation.isEmpty))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .appDialogTypography()
        .frame(width: 440)
        .disabled(isWorking)
        .interactiveDismissDisabled(isWorking)
        .onAppear { passwordFocused = true }
    }
}
