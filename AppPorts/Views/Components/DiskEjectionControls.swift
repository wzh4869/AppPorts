import SwiftUI
import AppKit

@MainActor
struct DiskEjectionControls: View {
    let externalURL: URL?
    let compact: Bool
    @ObservedObject private var controller = DiskEjectionController.shared
    @ObservedObject private var operations = AppOperationState.shared
    @ObservedObject private var images = AppLibraryImageController.shared

    private var selectedImage: AppLibraryImageService.Record? {
        guard let externalURL, let record = images.record,
              PortalImageLaunchPreparation.contains(externalURL.path, in: record.libraryPath ?? record.mountPath) else { return nil }
        return record
    }

    private var actionTitle: String { selectedImage == nil ? "弹出外置硬盘".localized : "卸载映像".localized }
    private var imagePaused: Bool {
        guard let record = selectedImage else { return false }
        return controller.imagePauses.contains { $0.imagePath == record.imagePath
            || $0.volumeUUIDs.contains(record.volumeUUID?.uppercased() ?? "") }
    }

    init(externalURL: URL?, controller: DiskEjectionController? = nil, compact: Bool = false) {
        self.externalURL = externalURL
        self.compact = compact
        self._controller = ObservedObject(wrappedValue: controller ?? .shared)
    }

    var body: some View {
        Menu {
            if controller.isRequestingEjection {
                if let image = selectedImage {
                    Text(String(format: "正在卸载「%@」".localized, URL(fileURLWithPath: image.imagePath).deletingPathExtension().lastPathComponent))
                } else {
                    Text("正在请求弹出，自动挂载已暂停。".localized)
                }
            }
            if imagePaused { Text("已暂停自动处理".localized) }
            if selectedImage != nil || controller.offersInitialEjection(at: externalURL) {
                Button(actionTitle) { controller.eject(at: externalURL) }
            }
            if !controller.pauses.isEmpty {
                if controller.offersInitialEjection(at: externalURL) { Divider() }
                ForEach(controller.pauses) { pause in
                    Section(header: Text(pause.displayName)) {
                        Text(controller.state(for: pause).statusText)
                        if controller.state(for: pause) == .online {
                            Button("重试弹出".localized) { controller.eject(at: nil, retrying: pause.id) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: controller.pauses.isEmpty && !imagePaused ? "eject" : "pause.circle")
                .frame(width: 26, height: 26)
        }
        .menuIndicator(compact ? .hidden : .visible)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(operations.isBusy || controller.isWorking)
        .accessibilityLabel(actionTitle)
        .help(selectedImage != nil ? "卸载映像并暂停自动挂载，选择“重新挂载映像”可恢复。".localized
            : controller.pauses.isEmpty ? "弹出整块外置硬盘及其所有卷。".localized
                : "此磁盘的自动挂载已暂停。请重新插入设备以恢复自动挂载。".localized)
        .task { await controller.observeDisks() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if controller.needsRefresh || !controller.pauses.isEmpty { Task { await controller.refresh() } }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await controller.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await controller.refresh() }
        }
        .alert(actionTitle, isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("好".localized, role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }
}
