import SwiftUI

/// A retained copy is ordinary success. Unfinished transactions expose their
/// recorded locations without offering an unsafe blanket retry or deletion.
struct DataTransferReviewView: View {
    let transfer: DataTransferRecord
    let onCleanup: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var verifiedApplication = false
    @State private var confirmCleanup = false
    @State private var contentHeight: CGFloat = 320

    private var canCleanup: Bool {
        [.awaitingUserVerification, .cleanupRequested].contains(transfer.phase) && transfer.baseline != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("副本管理".localized).font(.title2.weight(.semibold))
            Text(verbatim: transfer.appName + " · " + URL(fileURLWithPath: transfer.originalPath).lastPathComponent)
                .font(.headline)
                .lineLimit(2)
            ScrollView {
                reviewContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ReviewContentHeight.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(contentHeight, maximumContentHeight))
            .onPreferenceChange(ReviewContentHeight.self) { contentHeight = $0 }
            HStack {
                Spacer()
                Button("关闭".localized) { dismiss() }.keyboardShortcut(.cancelAction)
                if canCleanup {
                    Button("校验并清理原件".localized, role: .destructive) { confirmCleanup = true }
                        .disabled(!verifiedApplication)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .confirmationDialog("校验并清理原件".localized, isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("校验并清理原件".localized, role: .destructive) { dismiss(); onCleanup() }
            Button("取消".localized, role: .cancel) { }
        } message: {
            Text("仅在原件与已复制内容一致、且没有占用或路径冲突时清理。清理后无法通过这份原件撤销。".localized)
        }
    }

    /// Keep the decision buttons visible even with long recovery paths or error text.
    private var maximumContentHeight: CGFloat {
        min(520, max(200, (NSScreen.main?.visibleFrame.height ?? 768) - 220))
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(canCleanup ? "原件已保留，仍占用存储空间。验证应用与数据正常后，可以校验并清理。".localized
                            : "操作尚需检查，所有已记录的副本都会保留。请先检查这些位置，不要合并或覆盖数据。".localized)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            pathRow(title: "当前数据".localized, path: transfer.activePath)
            if canCleanup, transfer.mode == .mount, transfer.direction == .restore,
               let uuid = transfer.sourceIdentity.volumeUUID {
                VStack(alignment: .leading, spacing: 4) {
                    Text("保留原件".localized).font(.subheadline.weight(.medium))
                    Text(verbatim: "APFS · " + uuid).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else if let backup = transfer.backupPath {
                pathRow(title: "保留原件".localized, path: backup)
            }
            if !canCleanup, let staging = transfer.stagingPath { pathRow(title: "暂存副本".localized, path: staging) }
            if ![transfer.activePath, transfer.backupPath, transfer.stagingPath].compactMap({ $0 })
                .contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == URL(fileURLWithPath: transfer.destinationPath).standardizedFileURL.path }) {
                pathRow(title: "目标副本".localized, path: transfer.destinationPath)
            }
            if let uuid = transfer.createdVolumeUUID ?? transfer.sourceIdentity.volumeUUID {
                Text(verbatim: "Volume UUID: " + uuid).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let reason = transfer.recoverableReason {
                Text(verbatim: reason).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canCleanup {
                Toggle("我已验证应用与数据正常".localized, isOn: $verifiedApplication)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func pathRow(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            HStack(alignment: .top) {
                Text(verbatim: path).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .help("在访达中显示".localized)
                .accessibilityLabel("在访达中显示".localized)
                .fixedSize()
            }
        }
    }
}

private struct ReviewContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
