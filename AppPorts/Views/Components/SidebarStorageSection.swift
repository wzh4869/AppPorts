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
    let apps: [AppItem]
    @ObservedObject private var operations = AppOperationState.shared
    @ObservedObject private var images = AppLibraryImageController.shared
    @ObservedObject private var customDirectories = CustomDirConfigStore.shared
    @State private var localSpace: StorageSpaceSnapshot?
    @State private var targetSpace: StorageSpaceSnapshot?
    @State private var hasReadLocal = false
    @State private var hasReadTarget = false
    @State private var offloadedBytes: Int64?
    @State private var volumeRevision = 0

    private var estimateKey: String {
        [String(operations.recordsRevision), String(operations.isBusy), String(volumeRevision), directory?.path ?? "", images.record?.imagePath ?? ""]
            .joined(separator: "|") + apps.map { $0.id + $0.status }.joined(separator: "|")
            + customDirectories.configs.map { $0.localPath + $0.externalBasePath }.joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            spaceUsage(title: "本机磁盘".localized, snapshot: localSpace,
                       hasRead: hasReadLocal, offloaded: offloadedBytes)
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
        .task(id: estimateKey) {
            offloadedBytes = nil
            guard !operations.isBusy else { return }
            let apps = apps
            let configs = customDirectories.configs
            let image = images.record
            while !Task.isCancelled {
                let worker = Task.detached(priority: .utility) {
                    SidebarOffloadedSpace.estimate(apps: apps, configs: configs, image: image)
                }
                let value = await withTaskCancellationHandler(operation: { await worker.value },
                                                              onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                offloadedBytes = value
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { return }
            }
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

    private func spaceUsage(title: String, snapshot: StorageSpaceSnapshot?, hasRead: Bool,
                            offloaded: Int64? = nil) -> some View {
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
                    let saved = Double(min(offloaded ?? 0, snapshot.available)) / Double(snapshot.total)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geometry.size.width * snapshot.usedFraction)
                        Rectangle().fill(Color.orange)
                            .frame(width: geometry.size.width * saved)
                            .offset(x: geometry.size.width * snapshot.usedFraction)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                .accessibilityLabel(title + " · " + "使用率".localized)
                .accessibilityValue(snapshot.usedFraction.formatted(.percent))
                HStack(spacing: 4) {
                    Text("空余".localized)
                    Text(LocalizedByteCountFormatter.string(fromByteCount: snapshot.available)).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .help("已用".localized + " " + LocalizedByteCountFormatter.string(fromByteCount: snapshot.used)
                      + " · " + "总容量".localized + " " + LocalizedByteCountFormatter.string(fromByteCount: snapshot.total))
                if let offloaded {
                    Text(String(format: "已节省 %@ 堪比黄金的存储空间".localized,
                                LocalizedByteCountFormatter.string(fromByteCount: offloaded)))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.orange)
                        .help("橙色表示已确认在外部存储的数据大小估算；不等于实际释放空间。未连接、未完成或保留本地副本的数据不计入，色段最多占用当前空余部分。".localized)
                }
            } else {
                Text(hasRead ? "无法读取".localized : "正在检查…".localized).foregroundStyle(.secondary)
            }
        }
    }
}

/// A conservative logical-size estimate, never a claim about reclaimed APFS blocks.
private enum SidebarOffloadedSpace {
    private static func isExternal(_ url: URL, image: AppLibraryImageService.Record? = nil) -> Bool {
        // Disk images may omit volumeIsInternal. Resolve the known image's
        // backing storage first, instead of rejecting its virtual volume.
        if let image, url.path == image.mountPath || url.path.hasPrefix(image.mountPath + "/") {
            guard let expected = image.volumeUUID,
                  let actual = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                  actual.caseInsensitiveCompare(expected) == .orderedSame else { return false }
            return isExternal(URL(fileURLWithPath: image.imagePath))
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]) else { return false }
        return values.volumeIsInternal == false || values.volumeIsLocal == false
    }

    static func estimate(apps: [AppItem], configs: [CustomDirConfig],
                         image: AppLibraryImageService.Record?) -> Int64? {
        guard let inspection = try? ContainerMountStore.shared.recordsForInspection(),
              inspection.validationError == nil,
              let appTransfers = try? AppTransferStore.shared.records() else { return nil }
        let excludedSources = Set(inspection.cleanups.map { $0.mountRecord.mountPointPath }
            + inspection.transfers.map(\.originalPath)
            + inspection.preservedMaterials.map(\.originalPath)
            + appTransfers.filter { record in
                record.cleanupItems.contains { item in
                    item.role == .source && !item.completed
                        && FileManager.default.fileExists(atPath: item.path)
                }
            }.map(\.sourcePath))
        var targets: [URL] = []
        func add(source: URL, target: URL, isMount: Bool = false) {
            guard !excludedSources.contains(source.path),
                  (try? source.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal == true,
                  let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .volumeIsInternalKey]),
                  values.isDirectory == true, isExternal(target, image: image) else { return }
            if target.path.hasPrefix("/Volumes/") {
                guard let mounted = DiskUtility.mountedVolumePath(containing: target), mounted.hasPrefix("/Volumes/") else { return }
            }
            guard isMount || source.resolvingSymlinksInPath().standardizedFileURL == target.standardizedFileURL else { return }
            targets.append(target.standardizedFileURL)
        }
        for app in apps where app.status == AppStatus.linked {
            guard let target = try? CodeSigner.resolveAppURL(at: app.displayURL) else { continue }
            // Verified app portals need not be symbolic links.
            add(source: app.path, target: target, isMount: true)
        }
        for link in inspection.managedLinks {
            guard let actual = try? DataPathIdentity.capture(URL(fileURLWithPath: link.destinationPath)),
                  link.destinationIdentity.matchesFilesystemObject(actual) else { continue }
            add(source: URL(fileURLWithPath: link.originalPath), target: URL(fileURLWithPath: link.destinationPath))
        }
        for mount in inspection.mounts {
            guard (try? mount.mountPointURL.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString?.caseInsensitiveCompare(mount.volumeUUID) == .orderedSame else { continue }
            add(source: mount.mountPointURL, target: mount.mountPointURL, isMount: true)
        }
        for config in configs {
            add(source: config.localURL, target: config.externalDestinationURL)
        }
        var roots: [URL] = []
        for target in targets.sorted(by: { $0.path.count < $1.path.count }) {
            if !roots.contains(where: { target.path == $0.path || target.path.hasPrefix($0.path + "/") }) {
                roots.append(target)
            }
        }
        var bytes: Int64 = 0
        for root in roots {
            guard !Task.isCancelled else { return nil }
            let result = DirectorySizeTraversal.measure(at: root)
            guard result.isComplete else { continue }
            let sum = bytes.addingReportingOverflow(result.bytes)
            bytes = sum.overflow ? Int64.max : sum.partialValue
        }
        return Task.isCancelled ? nil : bytes
    }
}
