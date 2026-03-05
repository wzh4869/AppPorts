//
//  DataDirRowView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/3/4.
//

import SwiftUI

/// 数据目录列表行视图
struct DataDirRowView: View {
    let item: DataDirItem
    let isSelected: Bool
    let onMigrate: (DataDirItem) -> Void
    let onRestore: (DataDirItem) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: item.type.icon)
                    .font(.system(size: 16))
                    .foregroundColor(iconColor)
            }

            // 名称 + 路径 + 标签
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    // 优先级标签
                    PriorityBadge(priority: item.priority)
                }

                Text(item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // 说明文字
                Text(item.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            // 大小
            VStack(alignment: .trailing, spacing: 2) {
                if let size = item.size {
                    Text(size)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                } else if item.status != "已链接" {
                    Text("计算中...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.5))
                }

                // 状态徽章
                DataDirStatusBadge(status: item.status)
            }

            // 操作按钮
            operationButtons
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.1)
                      : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("在 Finder 中显示".localized) {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            }
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private var operationButtons: some View {
        if !item.isMigratable {
            // 不可迁移的目录：显示禁用按钮 + tooltip
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .help(item.nonMigratableReason ?? "此目录不支持迁移")
        } else if item.status == "已链接" {
            // 已链接：显示「还原」按钮
            Button(action: { onRestore(item) }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("还原".localized)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .controlSize(.small)
            .help("将数据目录还原到本地")
        } else if item.status == "本地" {
            // 本地：显示「迁移」按钮
            Button(action: { onMigrate(item) }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                    Text("迁移".localized)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .controlSize(.small)
            .help("将数据目录迁移到外部存储")
        }
    }

    private var iconColor: Color {
        switch item.priority {
        case .critical:    return .red
        case .recommended: return .orange
        case .optional:    return .blue
        }
    }
}

// MARK: - 优先级标签

struct PriorityBadge: View {
    let priority: DataDirPriority

    var body: some View {
        Text(priority.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var color: Color {
        switch priority {
        case .critical:    return .red
        case .recommended: return .orange
        case .optional:    return .blue
        }
    }
}

// MARK: - 状态徽章

struct DataDirStatusBadge: View {
    let status: String

    var body: some View {
        Text(status.localized)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .clipShape(Capsule())
    }

    private var foregroundColor: Color {
        switch status {
        case "已链接": return .green
        case "本地":   return .secondary
        default:       return .gray
        }
    }

    private var backgroundColor: Color {
        switch status {
        case "已链接": return .green.opacity(0.15)
        case "本地":   return Color(nsColor: .controlBackgroundColor)
        default:       return .gray.opacity(0.1)
        }
    }
}
