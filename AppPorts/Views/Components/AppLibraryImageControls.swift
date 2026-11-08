import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppLibraryImageController: ObservableObject {
    static let shared = AppLibraryImageController()
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published private(set) var record: AppLibraryImageService.Record?
    private var attemptedRestore = false
    private let service: AppLibraryImageService
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, service: AppLibraryImageService = AppLibraryImageService()) {
        self.defaults = defaults
        self.service = service
        reloadRecord()
    }

    func reloadRecord() {
        record = AppLibraryImageRecovery.loadRecord(defaults: defaults)
    }

    func create(directory: URL, name: String, capacityGiB: Int, onReady: @escaping (URL) -> Void) {
        guard AppInstallationLocation.confirmIfNeeded() else { return }
        perform(onReady: onReady) {
            let record = try await self.service.create(in: directory, name: name, capacityGiB: capacityGiB)
            // Save before attachment so a failed mount can be retried without
            // creating another image. Creation failures retain files in place.
            try self.save(record)
            return record
        }
    }

    func open(_ url: URL, onReady: @escaping (URL) -> Void) {
        guard AppInstallationLocation.confirmIfNeeded() else { return }
        perform(onReady: onReady) {
            self.record.flatMap { $0.imagePath == url.standardizedFileURL.path ? $0 : nil }
                ?? AppLibraryImageService.Record(imageURL: url)
        }
    }

    func remount(onReady: @escaping (URL) -> Void) {
        guard AppInstallationLocation.confirmIfNeeded() else { return }
        perform(onReady: onReady) { self.record }
    }

    func restoreIfSelected(onReady: @escaping (URL) -> Void) {
        guard AppInstallationLocation.isAllowed() else { return }
        reloadRecord()
        guard !attemptedRestore, AppLibraryImageRecovery.selectedRecord(defaults: defaults) != nil,
              !AppOperationState.shared.isBusy else { return }
        attemptedRestore = true
        perform(onReady: onReady, resumesImage: false) { AppLibraryImageRecovery.selectedRecord(defaults: self.defaults) }
    }

    private func save(_ record: AppLibraryImageService.Record) throws {
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        self.record = record
    }

    private func perform(onReady: @escaping (URL) -> Void, resumesImage: Bool = true,
                         prepare: @escaping () async throws -> AppLibraryImageService.Record?) {
        let operations = AppOperationState.shared
        guard !isWorking, let token = operations.begin() else { return }
        isWorking = true
        errorMessage = nil
        operations.startTask(for: token) {
            defer {
                self.isWorking = false
                operations.finish(token)
            }
            let lock = OperationLock()
            guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else {
                self.errorMessage = lock.diagnosticFailure(scope: .global).localizedDescription
                return
            }
            defer { lock.release() }
            do {
                try AppInstallationLocation.require()
                // The agent may have rebased or upgraded the record while we waited.
                self.reloadRecord()
                guard let record = try await prepare() else { return }
                let pauses = DiskEjectionPauseStore()
                if !resumesImage, try pauses.snapshot().blocksImage(record) { return }
                let mounted = try await self.service.mount(record)
                try self.save(mounted.record)
                if resumesImage { try pauses.resumeImage(mounted.record) }
                // Persist selection before registering the agent; SwiftUI's
                // onChange callback may otherwise run after this operation ends.
                self.defaults.set(mounted.libraryURL.path, forKey: "ExternalDrivePath")
                onReady(mounted.libraryURL)
                self.defaults.synchronize()
                ContainerMountAgentInstaller.installIfNeeded()
            } catch let pending as ShellCommandUnconfirmedTermination {
                self.errorMessage = pending.localizedDescription
                // A deadline is not proof that an image writer stopped. Keep
                // the shared operation token until its process actually exits.
                while (try? ProcessCommandRunner.isRunning(pending.process)) != false {
                    await Task.detached { try? await Task.sleep(nanoseconds: 1_000_000_000) }.value
                }
            } catch {
                self.errorMessage = error.localizedDescription
                AppLogger.shared.logContext("应用库映像操作失败", details: [("error", error.localizedDescription)], level: "ERROR")
            }
        }
    }
}

@MainActor
struct AppLibraryImageControls: View {
    let onReady: (URL) -> Void
    var onChooseLocation: (() -> Void)? = nil
    var hasLocation = false
    @ObservedObject private var controller = AppLibraryImageController.shared
    @ObservedObject private var operations = AppOperationState.shared
    @State private var showsCreation = false

    var body: some View {
        Menu {
            if let onChooseLocation {
                Button(hasLocation ? "更换位置".localized : "选择文件夹".localized, action: onChooseLocation)
                Divider()
            }
            Button("创建 APFS 映像".localized) {
                guard AppInstallationLocation.confirmIfNeeded() else { return }
                showsCreation = true
            }
            Button("打开已有映像…".localized) { openImage() }
            if controller.record != nil {
                Button("重新挂载映像".localized) { controller.remount(onReady: onReady) }
            }
        } label: {
            if controller.isWorking {
                ProgressView().controlSize(.small)
            } else if onChooseLocation != nil {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            } else {
                Text("磁盘映像".localized)
            }
        }
        .accessibilityLabel(onChooseLocation == nil ? "磁盘映像".localized : "更换位置".localized)
        .help(onChooseLocation == nil ? "磁盘映像".localized : "更换位置".localized)
        .menuIndicator(onChooseLocation == nil ? .visible : .hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(operations.isBusy)
        .sheet(isPresented: $showsCreation) {
            AppLibraryImageCreationSheet { directory, name, capacity in
                showsCreation = false
                controller.create(directory: directory, name: name, capacityGiB: capacity, onReady: onReady)
            }
        }
        .alert("磁盘映像".localized, isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("好".localized, role: .cancel) { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .task {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            controller.restoreIfSelected(onReady: onReady)
        }
    }

    private func openImage() {
        guard AppInstallationLocation.confirmIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sparsebundle") ?? .diskImage]
        if panel.runModal() == .OK, let url = panel.url { controller.open(url, onReady: onReady) }
    }
}

private struct AppLibraryImageCreationSheet: View {
    let onCreate: (URL, String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory: URL?
    @State private var name = "AppPorts"
    @State private var capacity = "256"
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("创建 APFS 映像".localized).font(AppDialogTypography.title)
                Spacer()
            }
            HStack {
                Text("存放位置".localized)
                Text(directory?.path ?? "未选择".localized)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("选择文件夹".localized) { chooseDirectory() }
            }
            TextField("磁盘名称".localized, text: $name)
            HStack {
                Text("最大容量（GiB）".localized)
                TextField("最大容量（GiB）".localized, text: $capacity)
                    .frame(width: 100)
            }
            Text("映像按实际写入占用空间，可存放在已挂载的 SMB 共享中。同一映像请只在一台 Mac 上写入。".localized)
                .font(AppDialogTypography.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(AppDialogTypography.body) }
            HStack {
                Button("取消".localized) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("创建并使用".localized) {
                    guard let directory else { return }
                    do {
                        let size = Int(capacity) ?? 0
                        try AppLibraryImageService.validate(name: name, capacityGiB: size)
                        onCreate(directory, name, size)
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(directory == nil || name.isEmpty || capacity.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .appDialogTypography()
        .frame(width: 500)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { directory = panel.url }
    }
}
