//
//  CustomDirRowView.swift
//  AppPorts
//
//  Created by Codex on 2026/6/26.
//

import SwiftUI
import AppKit

struct CustomDirRowView: View {
    let entry: CustomDirEntry
    let isSelected: Bool
    let onDeleteLink: (CustomDirEntry) -> Void
    let onRemove: (CustomDirConfig) -> Void

    @State private var isHovered = false

    private var showsDeleteLinkButton: Bool {
        entry.kind == .local
            && (entry.status == CustomDirStatus.linked || entry.status == CustomDirStatus.orphanedLink)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.kind == .local ? "folder.fill" : "externaldrive.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(entry.kind == .local ? .accentColor : .teal)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(entry.url.path)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    CustomDirStatusBadge(status: entry.status)

                    if let size = entry.size {
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if entry.status != CustomDirStatus.missing {
                        Text("计算中...".localized)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }

            Spacer()

            if showsDeleteLinkButton {
                Button(action: { onDeleteLink(entry) }) {
                    Image(systemName: "link.badge.plus")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.red.opacity(0.1))
                .clipShape(Circle())
                .help("断开此链接并保留外部文件夹".localized)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entry.name) + Text(", ") + Text(entry.status.localized))
        .contextMenu {
            Button("在 Finder 中显示".localized) {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }

            if showsDeleteLinkButton {
                Divider()
                Button("断开链接".localized) {
                    onDeleteLink(entry)
                }
            }

            Divider()

            Button("移除记录".localized) {
                onRemove(entry.config)
            }
        }
    }
}

private struct CustomDirStatusBadge: View {
    let status: String

    private var color: Color {
        switch status {
        case CustomDirStatus.local:
            return .blue
        case CustomDirStatus.linked:
            return .green
        case CustomDirStatus.pendingRelink:
            return .orange
        case CustomDirStatus.orphanedLink, CustomDirStatus.destinationConflict:
            return .red
        default:
            return .secondary
        }
    }

    var body: some View {
        Text(status.localized)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(5)
    }
}
