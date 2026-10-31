//
//  SignatureRepairSheet.swift
//  AppPorts
//

import SwiftUI

/// 先还原旧容器链接，再恢复原始应用。迁回本机仅是覆盖安装前的准备，
/// 不作为从完整备份恢复外置应用的前置条件。
struct SignatureRepairSheet: View {
    let app: AppItem
    let onRestoreSignature: (AppItem) -> Void
    /// 迁回本地（复用应用页的还原流程），面板会先关闭
    let onMoveBack: (AppItem) -> Void
    /// 跳到「应用数据」页并选中该应用
    let onOpenDataDirs: (AppItem) -> Void
    let onDismiss: () -> Void
    var onChooseOfficialOriginal: ((AppItem) -> Void)? = nil

    @ObservedObject private var languageManager = LanguageManager.shared
    @ObservedObject private var operationState = AppOperationState.shared

    @State private var linkedContainerItems: [DataDirItem] = []
    @State private var isScanning = true
    @State private var isRestoring = false
    @State private var restoreProgressText = ""
    @State private var errorMessage: String?
    @State private var cleanupWarning: String?
    @State private var realAppURL: URL?
    @State private var currentAuthority: String?
    @State private var signatureRestored = false
    @State private var isCheckingSignature = false
    @State private var signatureCheckToken = UUID()
    @State private var containerScanToken = UUID()
    @State private var containerReadIssues: [DataDirReadIssue] = []
    @State private var containerIdentityIssue: AppIdentityIssue?

    private var appIsOnExternalDrive: Bool {
        app.status == AppStatus.linked || app.status == AppStatus.partialLinked
    }

    private var stepOneDone: Bool { !isScanning && containerIdentityIssue == nil && containerReadIssues.isEmpty && linkedContainerItems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                AppIconView(url: app.displayURL, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "修复「%@」的签名".localized, app.displayName))
                        .font(AppDialogTypography.title)
                    Text("先还原应用数据，再恢复原始签名。请退出应用并连接外置盘。AppPorts 会处理备份。".localized)
                        .font(AppDialogTypography.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            stepRow(
                number: 1,
                title: "还原容器数据".localized,
                done: stepOneDone,
                detail: isScanning
                    ? "正在检查容器目录…".localized
                    : (containerIdentityIssue != nil || !containerReadIssues.isEmpty
                        ? "相关容器未能完整检查，请重新检查或先选择官方原件。".localized
                        : linkedContainerItems.isEmpty
                        ? "当前检查未发现经典容器链接；恢复时还会核对官方原件声明的共享容器。".localized
                        : String(format: "还有 %lld 个容器目录指向外置盘。重装前必须先还原，否则重装后应用仍读不到数据。".localized, Int64(linkedContainerItems.count)))
            ) {
                if !linkedContainerItems.isEmpty {
                    Button(isRestoring ? "正在还原…".localized : "全部还原".localized) {
                        restoreAllContainerItems()
                    }
                    .disabled(isRestoring || isScanning || operationState.isBusy)
                }
            }
            if isRestoring, !restoreProgressText.isEmpty {
                Text(restoreProgressText)
                    .font(AppDialogTypography.body)
                    .foregroundColor(.secondary)
                    .padding(.leading, 34)
            }

            stepRow(
                number: 2,
                title: "恢复原始签名或从官方渠道重装".localized,
                done: signatureRestored,
                detail: isCheckingSignature
                    ? "正在检查签名…".localized
                    : (signatureRestored
                        ? String(format: "签名已恢复：%@".localized, currentAuthority ?? "")
                        : String(format: "当前签名：%@。可使用已有原版备份或选择同版本官方原件修复；也可以从 App Store 或官网下载重装。应用数据目录不会被替换。".localized,
                                 currentAuthority ?? "暂时无法检查签名".localized))
            ) {
                if !signatureRestored {
                    Button("恢复原始签名".localized) {
                        onDismiss()
                        onRestoreSignature(app)
                    }
                    .disabled(isScanning || isCheckingSignature || operationState.isBusy || app.isRunning)
                    if let onChooseOfficialOriginal {
                        Button("选择原版应用…".localized) {
                            onDismiss()
                            onChooseOfficialOriginal(app)
                        }
                        .disabled(operationState.isBusy || app.isRunning)
                    }
                }
                Button("重新检查".localized) {
                    refreshSignatureState()
                    scanContainerItems()
                }
                .disabled(isCheckingSignature || isRestoring || operationState.isBusy)
                if isCheckingSignature { ProgressView().controlSize(.small) }
            }
            if !signatureRestored {
                DisclosureGroup("从官方渠道重装".localized) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appIsOnExternalDrive
                             ? "仅在覆盖安装前需要迁回本地。使用原版备份或官方原件可以直接修复外置盘上的应用。".localized
                             : "应用本体在本地。".localized)
                            .font(AppDialogTypography.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if appIsOnExternalDrive {
                            Button("迁回本地".localized) {
                                onDismiss()
                                onMoveBack(app)
                            }
                            .disabled(operationState.isBusy || app.isRunning)
                        } else if app.isAppStoreApp {
                            Button("打开 App Store".localized) { openAppStore() }
                                .disabled(!stepOneDone || operationState.isBusy)
                        } else {
                            Button("在 Finder 中显示".localized) {
                                NSWorkspace.shared.activateFileViewerSelecting([realAppURL ?? app.displayURL])
                            }
                        }
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 34)
            }

            stepRow(
                number: 3,
                title: "可选：用挂载迁移把数据放回外置盘".localized,
                done: false,
                detail: "签名检查通过后，请先从 Finder 或 Dock 打开应用并确认数据正常，再到「应用数据」页迁移。".localized
            ) {
                Button("前往应用数据".localized) {
                    onDismiss()
                    onOpenDataDirs(app)
                }
                .disabled(!stepOneDone || !signatureRestored || operationState.isBusy)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(AppDialogTypography.body)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cleanupWarning {
                Text(cleanupWarning)
                    .font(AppDialogTypography.body)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Link("查看完整说明".localized, destination: DocumentationLink.url(page: "macos-27"))
                    .font(AppDialogTypography.body)
                Spacer()
                Button(signatureRestored ? "关闭".localized : "以后再说".localized) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .appDialogTypography()
        .frame(width: 560)
        .onAppear {
            refreshSignatureState()
            scanContainerItems()
        }
        .onChange(of: operationState.recordsRevision) { _ in
            refreshSignatureState()
            scanContainerItems()
        }
        .onDisappear {
            signatureCheckToken = UUID()
            containerScanToken = UUID()
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private func stepRow<Actions: View>(
        number: Int,
        title: String,
        done: Bool,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.15) : Color.primary.opacity(0.06))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppDialogTypography.title)
                    .foregroundColor(done ? .secondary : .primary)
                Text(detail)
                    .font(AppDialogTypography.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 状态刷新

    private func refreshSignatureState() {
        let token = UUID()
        signatureCheckToken = token
        signatureRestored = false
        currentAuthority = nil
        guard let url = try? CodeSigner.resolveAppURL(at: app.displayURL) else {
            realAppURL = nil
            isCheckingSignature = false
            return
        }
        realAppURL = url
        isCheckingSignature = true
        Task.detached(priority: .userInitiated) {
            let signer = CodeSigner()
            let signing = await AppScanner().checkSigningStatus(bundleURL: url)
            let authority = await signer.getSigningIdentity(appURL: url)
            let official = await signer.isVerifiedOfficialApplication(appURL: url)
            await MainActor.run {
                guard signatureCheckToken == token else { return }
                currentAuthority = signing.signatureCheckUnavailable ? nil : (signing.isResigned ? "Ad-hoc" : authority)
                signatureRestored = !signing.signatureCheckUnavailable && !signing.isResigned && official
                isCheckingSignature = false
            }
        }
    }

    private func scanContainerItems() {
        let token = UUID()
        containerScanToken = token
        isScanning = true
        Task {
            let scan = await DataDirScanner().scanLibraryDirsWithDiagnostics(for: app)
            let linked = scan.items.filter {
                ($0.type == .containers || $0.type == .groupContainers)
                    && !$0.isUserDirectoryLink && $0.linkedDestination != nil
                    && [DataDirStatus.linked, DataDirStatus.needsNormalization, DataDirStatus.existingSymlink].contains($0.status)
            }
            guard containerScanToken == token else { return }
            linkedContainerItems = linked
            containerReadIssues = scan.readIssues
            containerIdentityIssue = scan.identityIssue
            if let issue = scan.identityIssue {
                errorMessage = "无法确认应用身份，请重新检查：".localized + issue.url.path
            }
            isScanning = false
        }
    }

    // MARK: - 动作

    private func restoreAllContainerItems() {
        let workflow = SignatureRepairRestoreWorkflow(
            appURL: app.displayURL,
            runningApplications: {
                NSWorkspace.shared.runningApplications.map {
                    AppRunningState.RunningApplication(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
                }
            }
        )
        let token: UUID
        switch workflow.begin(operationState: AppOperationState.shared) {
        case .started(let operationToken):
            token = operationToken
        case .appRunning:
            showAppRunningRestoreError()
            return
        case .busy:
            return
        }
        isRestoring = true
        errorMessage = nil
        cleanupWarning = nil
        let items = linkedContainerItems
        AppLogger.shared.logContext(
            "修复面板：批量还原容器目录",
            details: [("app_name", app.displayName), ("count", String(items.count))]
        )
        operationState.startTask(for: token) { @MainActor in
            let lock = OperationLock()
            let acquired = await lock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                isRestoring = false
                if acquired { lock.release() }
                AppOperationState.shared.finish(token)
                scanContainerItems()
            }
            guard acquired else {
                errorMessage = lock.admissionFailureReason ?? "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                return
            }
            let mover = DataDirMover()
            let outcome = await workflow.run(items: items) { item, index in
                restoreProgressText = String(format: "正在还原 %lld / %lld：%@".localized, Int64(index + 1), Int64(items.count), item.name)
                let result = try await mover.restoreAndComplete(item: item) { progress in
                    await MainActor.run {
                        if progress.showsByteProgress {
                            restoreProgressText = String(
                                format: "正在还原 %lld / %lld：%@（%@）".localized,
                                Int64(index + 1), Int64(items.count), item.name,
                                LocalizedByteCountFormatter.string(fromByteCount: progress.copiedBytes)
                            )
                        } else {
                            restoreProgressText = item.name + " · " + progress.currentFile
                        }
                    }
                }
                if let warning = result.cleanupWarning {
                    cleanupWarning = [cleanupWarning, warning].compactMap { $0 }.joined(separator: "\n\n")
                }
            }
            switch outcome {
            case .completed:
                break
            case .appRunning:
                showAppRunningRestoreError()
            case .restoreFailed(let item, let error):
                AppLogger.shared.logError(
                    "修复面板：还原容器目录失败",
                    error: error,
                    errorCode: "SIGNATURE-REPAIR-RESTORE-FAILED",
                    context: [("app_name", app.displayName), ("item_name", item.name)],
                    relatedURLs: [("local", item.path)]
                )
                errorMessage = String(format: "「%@」还原失败：%@".localized, item.name, error.localizedDescription)
            }
        }
    }

    private func showAppRunningRestoreError() {
        errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再还原其数据目录。".localized, app.displayName)
        AppLogger.shared.logContext(
            "修复面板：拒绝还原正在运行的应用数据",
            details: [("app_name", app.displayName), ("app_path", app.displayURL.path)],
            level: "WARN"
        )
    }

    private func openAppStore() {
        if let url = URL(string: "macappstore://apps.apple.com/") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 修复面板的批量还原边界。保存的是进程查询，而不是查询结果；开始批次和每个目录动手前都重新读取。
@MainActor
struct SignatureRepairRestoreWorkflow {
    enum StartResult: Equatable {
        case started(UUID)
        case appRunning
        case busy
    }

    enum Outcome {
        case completed
        case appRunning
        case restoreFailed(item: DataDirItem, error: Error)
    }

    let appURL: URL
    let runningApplications: @MainActor () -> [AppRunningState.RunningApplication]

    /// 同步申请令牌，保持按钮点击与进入忙碌状态之间没有异步空隙。
    func begin(operationState: AppOperationState) -> StartResult {
        guard !appIsRunning else { return .appRunning }
        guard let token = operationState.begin() else { return .busy }
        return .started(token)
    }

    func run(
        items: [DataDirItem],
        restore: @MainActor (DataDirItem, Int) async throws -> Void
    ) async -> Outcome {
        for (index, item) in items.enumerated() {
            // 上一个目录还原期间应用可能重新启动，不能复用批次开始时的检查结果。
            guard !appIsRunning else { return .appRunning }
            do {
                try Task.checkCancellation()
                try await restore(item, index)
            } catch {
                return .restoreFailed(item: item, error: error)
            }
        }
        return .completed
    }

    private var appIsRunning: Bool {
        AppRunningState.isRunning(appURL: appURL, applications: runningApplications())
    }
}
