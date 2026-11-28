import AppKit
import SwiftUI

/// Volume capacity is display-only; it does not authorize a migration or cleanup.
struct StorageSpaceSnapshot: Sendable {
    let total: Int64
    let available: Int64
    var used: Int64 { total - available }
    var usedFraction: Double { Double(used) / Double(total) }

    static func read(at directory: URL) -> Self? {
        var fresh = URL(fileURLWithPath: directory.path)
        fresh.removeAllCachedResourceValues()
        if directory.path.hasPrefix("/Volumes/") {
            guard let mount = DiskUtility.mountedVolumePath(containing: directory),
                  mount.hasPrefix("/Volumes/") else { return nil }
        }
        guard let values = try? fresh.resourceValues(forKeys: [.isDirectoryKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              values.isDirectory == true,
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacity, available >= 0 else { return nil }
        return Self(total: Int64(total), available: min(Int64(available), Int64(total)))
    }
}

@MainActor
struct SidebarTargetSection: View {
    let directory: URL?
    let showsTarget: Bool
    let onChoose: () -> Void
    let onImageReady: (URL) -> Void
    @ObservedObject private var images = AppLibraryImageController.shared
    @State private var isChooseHovered = false

    private var selectedImage: AppLibraryImageService.Record? {
        guard let directory, let record = images.record,
              directory.path == record.libraryPath || directory.path == record.mountPath else { return nil }
        return record
    }

    private var displayName: String {
        if let image = selectedImage {
            return URL(fileURLWithPath: image.imagePath).deletingPathExtension().lastPathComponent
        }
        return directory?.lastPathComponent ?? "未选择".localized
    }

    var body: some View {
        if showsTarget {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("目标存储".localized)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if directory == nil {
                        AppLibraryImageControls(onReady: onImageReady,
                                                onChooseLocation: onChoose, hasLocation: false)
                            .controlSize(.small)
                    }
                }
                if let directory {
                    HStack(alignment: .center, spacing: 6) {
                        Text(verbatim: displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        HStack(spacing: 2) {
                            DiskEjectionControls(externalURL: directory, compact: true)
                            AppLibraryImageControls(onReady: onImageReady,
                                                    onChooseLocation: onChoose, hasLocation: true)
                        }
                        .controlSize(.small)
                    }
                    Text(verbatim: directory.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(directory.path)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("复制路径".localized) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(directory.path, forType: .string)
                            }
                        }
                } else {
                    Button(action: onChoose) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11, weight: .medium))
                            Text("选择文件夹".localized)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(isChooseHovered ? 0.09 : 0.055))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .onHover { isChooseHovered = $0 }
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

@MainActor
struct SidebarStorageSection: View {
    let directory: URL?
    let showsTarget: Bool
    @ObservedObject private var operations = AppOperationState.shared
    @ObservedObject private var diskEjection = DiskEjectionController.shared
    @State private var localSpace: StorageSpaceSnapshot?
    @State private var targetSpace: StorageSpaceSnapshot?
    @State private var hasReadLocal = false
    @State private var hasReadTarget = false
    @State private var volumeRevision = 0
    @State private var unmountingVolumePaths: Set<String> = []
    @State private var unmountGraceTask: Task<Void, Never>?

    private var isTargetSuppressed: Bool {
        guard let directory else { return false }
        if diskEjection.suppressesVolumeAccess(at: directory) { return true }
        return unmountingVolumePaths.contains { DiskEjectionController.path(directory.path, isWithin: $0) }
    }

    private var storageTaskID: String {
        "\(showsTarget)-\(directory?.path ?? "")-\(operations.recordsRevision)-\(volumeRevision)-\(isTargetSuppressed)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            spaceUsage(title: "本机磁盘".localized, snapshot: localSpace,
                       hasRead: hasReadLocal)
            if showsTarget, directory != nil {
                spaceUsage(title: "目标存储".localized, snapshot: targetSpace, hasRead: hasReadTarget)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willUnmountNotification)) { notification in
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            let volumePath = DiskEjectionController.standardizedPath(volumeURL.path)
            unmountingVolumePaths.insert(volumePath)
            unmountGraceTask?.cancel()
            unmountGraceTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                unmountingVolumePaths.remove(volumePath)
                unmountGraceTask = nil
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { notification in
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                unmountingVolumePaths.remove(DiskEjectionController.standardizedPath(volumeURL.path))
            } else {
                unmountingVolumePaths.removeAll()
            }
            if unmountingVolumePaths.isEmpty {
                unmountGraceTask?.cancel()
                unmountGraceTask = nil
            }
            volumeRevision += 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { notification in
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                unmountingVolumePaths.remove(DiskEjectionController.standardizedPath(volumeURL.path))
            } else {
                unmountingVolumePaths.removeAll()
            }
            if unmountingVolumePaths.isEmpty {
                unmountGraceTask?.cancel()
                unmountGraceTask = nil
            }
            volumeRevision += 1
        }
        .onDisappear {
            unmountGraceTask?.cancel()
            unmountGraceTask = nil
            unmountingVolumePaths.removeAll()
        }
        .task(id: storageTaskID) {
            let target = showsTarget ? directory : nil
            let suppressed = isTargetSuppressed
            if !suppressed || target == nil {
                hasReadTarget = false
                targetSpace = nil
            }
            while !Task.isCancelled {
                let local = await Task.detached(priority: .utility) {
                    let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
                    return StorageSpaceSnapshot.read(at: dataVolume)
                        ?? StorageSpaceSnapshot.read(at: URL(fileURLWithPath: "/"))
                }.value
                guard !Task.isCancelled else { return }
                localSpace = local
                hasReadLocal = true
                if suppressed {
                    if let target, DiskEjectionController.mountedExternalVolumeRoot(for: target) == nil {
                        targetSpace = nil
                        hasReadTarget = true
                    }
                } else {
                    let external = await Task.detached(priority: .utility) {
                        target.flatMap { StorageSpaceSnapshot.read(at: $0) }
                    }.value
                    guard !Task.isCancelled else { return }
                    targetSpace = external
                    hasReadTarget = true
                }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
    }

    private func spaceUsage(title: String, snapshot: StorageSpaceSnapshot?, hasRead: Bool) -> some View {
        let formattingLocale = LanguageManager.shared.formattingLocale
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 4)
                if let snapshot {
                    Text(snapshot.usedFraction.formatted(.percent.precision(.fractionLength(0)).locale(formattingLocale)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                capacityBar(fraction: snapshot.usedFraction, label: title, locale: formattingLocale)
                capacitySummary(for: snapshot)
            } else {
                Text(hasRead ? "无法读取".localized : "正在检查…".localized).foregroundStyle(.secondary)
            }
        }
    }

    private func capacityBar(fraction: Double, label: String, locale: Locale) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Rectangle().fill(Color.accentColor)
                    .frame(width: geometry.size.width * fraction)
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .accessibilityLabel(label + " · " + "使用率".localized)
        .accessibilityValue(fraction.formatted(.percent.locale(locale)))
    }

    private func usedAndTotalHelpText(for snapshot: StorageSpaceSnapshot) -> String {
        let usedSize = LocalizedByteCountFormatter.string(fromByteCount: snapshot.used)
        let totalSize = LocalizedByteCountFormatter.string(fromByteCount: snapshot.total)
        return "已用".localized + " " + usedSize + " · " + "总容量".localized + " " + totalSize
    }

    private func capacitySummary(for snapshot: StorageSpaceSnapshot) -> some View {
        let availableSize = LocalizedByteCountFormatter.string(fromByteCount: snapshot.available)
        return HStack(spacing: 4) {
            Text("空余".localized)
            Text(availableSize).monospacedDigit()
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .help(usedAndTotalHelpText(for: snapshot))
    }
}
