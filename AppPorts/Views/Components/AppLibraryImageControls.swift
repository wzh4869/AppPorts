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
    private let service = AppLibraryImageService()

    init() {
        if let data = UserDefaults.standard.data(forKey: AppLibraryImageService.preferenceKey) {
            record = try? JSONDecoder().decode(AppLibraryImageService.Record.self, from: data)
        }
    }

    func create(directory: URL, name: String, capacityGiB: Int, onReady: @escaping (URL) -> Void) {
        perform(onReady: onReady) {
            let record = try await self.service.create(in: directory, name: name, capacityGiB: capacityGiB)
            // Save before attachment so a failed mount can be retried without
            // creating another image. Creation failures retain files in place.
            try self.save(record)
            return record
        }
    }

    func open(_ url: URL, onReady: @escaping (URL) -> Void) {
        perform(onReady: onReady) { AppLibraryImageService.Record(imageURL: url) }
    }

    func remount(onReady: @escaping (URL) -> Void) {
        guard let record else { return }
        perform(onReady: onReady) { record }
    }

    func restoreIfSelected(onReady: @escaping (URL) -> Void) {
        guard !attemptedRestore, let record,
              UserDefaults.standard.string(forKey: "ExternalDrivePath") == (record.libraryPath ?? record.mountPath),
              !AppOperationState.shared.isBusy else { return }
        attemptedRestore = true
        remount(onReady: onReady)
    }

    private func save(_ record: AppLibraryImageService.Record) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(record), forKey: AppLibraryImageService.preferenceKey)
        self.record = record
    }

    private func perform(onReady: @escaping (URL) -> Void,
                         prepare: @escaping () async throws -> AppLibraryImageService.Record) {
        let operations = AppOperationState.shared
        guard !isWorking, let token = operations.begin() else { return }
        isWorking = true
        errorMessage = nil
        operations.startTask(for: token) {
            defer {
                self.isWorking = false
                operations.finish(token)
            }
            do {
                let record = try await prepare()
                let mounted = try await self.service.mount(record)
                try self.save(mounted.record)
                onReady(mounted.libraryURL)
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
    @ObservedObject private var controller = AppLibraryImageController.shared
    @ObservedObject private var operations = AppOperationState.shared
    @State private var showsCreation = false

    var body: some View {
        Menu {
            Button("创建 APFS 映像".localized) { showsCreation = true }
            Button("打开已有映像…".localized) { openImage() }
            if controller.record != nil {
                Button("重新挂载映像".localized) { controller.remount(onReady: onReady) }
            }
        } label: {
            if controller.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Text("磁盘映像".localized)
            }
        }
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
                Button("取消".localized) { dismiss() }.keyboardShortcut(.cancelAction)
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
            Text("以后使用映像中的应用前，请先打开 AppPorts 挂载映像。退出 AppPorts 不会卸载映像。".localized)
                .font(AppDialogTypography.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(AppDialogTypography.body) }
            HStack {
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
