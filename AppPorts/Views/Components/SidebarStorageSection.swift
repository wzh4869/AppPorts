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
    @ObservedObject private var operations = AppOperationState.shared
    @ObservedObject private var images = AppLibraryImageController.shared
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
            VStack(alignment: .leading, spacing: 3) {
                Text("目标存储".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(verbatim: displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(directory == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    DiskEjectionControls(externalURL: directory, compact: true)
                    AppLibraryImageControls(onReady: onImageReady,
                                            onChooseLocation: onChoose, hasLocation: directory != nil)
                }
                if let directory {
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
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
    }
}

@MainActor
struct SidebarStorageSection: View {
    let directory: URL?
    let showsTarget: Bool
    @ObservedObject private var operations = AppOperationState.shared
    @State private var localSpace: StorageSpaceSnapshot?
    @State private var targetSpace: StorageSpaceSnapshot?
    @State private var hasReadLocal = false
    @State private var hasReadTarget = false
    @State private var volumeRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            spaceUsage(title: "本机磁盘".localized, snapshot: localSpace,
                       hasRead: hasReadLocal)
            if showsTarget, directory != nil {
                spaceUsage(title: "目标存储".localized, snapshot: targetSpace, hasRead: hasReadTarget)
            }
        }
        .font(.system(size: 11))
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumeRevision += 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumeRevision += 1
        }
        .task(id: "\(showsTarget)-\(directory?.path ?? "")-\(operations.recordsRevision)-\(volumeRevision)") {
            hasReadTarget = false
            targetSpace = nil
            let target = showsTarget ? directory : nil
            while !Task.isCancelled {
                let local = await Task.detached(priority: .utility) {
                    let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
                    return StorageSpaceSnapshot.read(at: dataVolume)
                        ?? StorageSpaceSnapshot.read(at: URL(fileURLWithPath: "/"))
                }.value
                guard !Task.isCancelled else { return }
                localSpace = local
                hasReadLocal = true
                let external = await Task.detached(priority: .utility) {
                    target.flatMap { StorageSpaceSnapshot.read(at: $0) }
                }.value
                guard !Task.isCancelled else { return }
                targetSpace = external
                hasReadTarget = true
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
    }

    private func spaceUsage(title: String, snapshot: StorageSpaceSnapshot?, hasRead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 4)
                if let snapshot {
                    Text(snapshot.usedFraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geometry.size.width * snapshot.usedFraction)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                .accessibilityLabel(title + " · " + "使用率".localized)
                .accessibilityValue(snapshot.usedFraction.formatted(.percent))
                capacitySummary(for: snapshot)
            } else {
                Text(hasRead ? "无法读取".localized : "正在检查…".localized).foregroundStyle(.secondary)
            }
        }
    }

    private func capacitySummary(for snapshot: StorageSpaceSnapshot) -> some View {
        let availableSize: String = LocalizedByteCountFormatter.string(fromByteCount: snapshot.available)
        let usedSize: String = LocalizedByteCountFormatter.string(fromByteCount: snapshot.used)
        let totalSize: String = LocalizedByteCountFormatter.string(fromByteCount: snapshot.total)
        let usedDescription: String = "已用".localized + " " + usedSize
        let totalDescription: String = "总容量".localized + " " + totalSize
        let helpText: String = usedDescription + " · " + totalDescription

        return HStack(spacing: 4) {
            Text("空余".localized)
            Text(availableSize).monospacedDigit()
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .help(helpText)
    }
}
