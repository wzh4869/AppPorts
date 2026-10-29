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

    private var showsDeleteLinkButton: Bool {
        entry.kind == .local
            && (entry.status == CustomDirStatus.linked || entry.status == CustomDirStatus.orphanedLink)
    }

    var body: some View {
        AppListColumns {
            HStack(spacing: 10) {
                Image(systemName: entry.kind == .local ? "folder.fill" : "externaldrive.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(entry.kind == .local ? .accentColor : .teal)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(entry.name)
                    Text(entry.url.path)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.url.path)
                    CustomDirStatusBadge(status: entry.status)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        } size: {
            Text(entry.size ?? (entry.status == CustomDirStatus.missing ? "—" : "计算中...".localized))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        } actions: {
            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多操作".localized)
            .help("更多操作".localized)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(AppListSelectionAppearance())
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("在 Finder 中显示".localized) {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        if showsDeleteLinkButton {
            Divider()
            Button("断开链接".localized) { onDeleteLink(entry) }
        }
        Divider()
        Button("移除记录".localized) { onRemove(entry.config) }
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
        Text(CustomDirStatus.localized(status))
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(5)
    }
}
