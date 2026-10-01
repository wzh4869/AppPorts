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
    var level: Int = 0
    let onMigrate: (DataDirItem) -> Void
    let onRestore: (DataDirItem) -> Void
    let onManageExistingLink: (DataDirItem) -> Void
    let onNormalizeManagedLink: (DataDirItem) -> Void
    let onRelinkExternalData: (DataDirItem) -> Void
    /// 挂载迁移相关操作（仅应用数据页的沙盒应用容器项使用）
    var onMountMigrate: ((DataDirItem) -> Void)? = nil
    var onMount: ((DataDirItem) -> Void)? = nil
    var onUnmount: ((DataDirItem) -> Void)? = nil
    var onMountRestore: ((DataDirItem) -> Void)? = nil
    /// 经典模式：容器目录同时提供符号链接「迁移」
    var classicModeActive: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // 树形缩进指示
            if level > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<level, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                            .frame(height: 16)
                            .padding(.leading, 8)
                            .padding(.trailing, 8)
                    }
                }
                .fixedSize()
            }
            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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

                    if item.requiresMountMigration {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 10))
                            .foregroundColor(.purple.opacity(0.8))
                            .help("沙盒应用：容器数据只能通过挂载迁移放到外部存储，符号链接会被系统拒绝".localized)
                    }
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
                } else {
                    Text("计算中...".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.5))
                }

                // 状态徽章
                DataDirStatusBadge(status: item.displayedStatus)
            }

            // 操作按钮
            operationButtons
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.15)
                      : (isHovered ? Color(nsColor: .controlBackgroundColor) : .clear))
                .shadow(color: isHovered && !isSelected ? Color.black.opacity(0.04) : .clear, radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : (isHovered ? Color.primary.opacity(0.05) : .clear), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("在 Finder 中显示".localized) {
                NSWorkspace.shared.activateFileViewerSelecting([item.linkedDestination ?? item.path])
            }
        }
    }

    private var operationButtons: some View {
        DataDirOperationButtons(
            item: item,
            onMigrate: onMigrate,
            onRestore: onRestore,
            onManageExistingLink: onManageExistingLink,
            onNormalizeManagedLink: onNormalizeManagedLink,
            onRelinkExternalData: onRelinkExternalData,
            onMountMigrate: onMountMigrate,
            onMount: onMount,
            onUnmount: onUnmount,
            onMountRestore: onMountRestore,
            classicModeActive: classicModeActive
        )
    }

    private var iconColor: Color {
        switch item.priority {
        case .critical:    return .red
        case .recommended: return .orange
        case .optional:    return .blue
        }
    }
}

/// Shared by tool rows and the selected application directory's detail area.
struct DataDirOperationButtons: View {
    let item: DataDirItem
    let onMigrate: (DataDirItem) -> Void
    let onRestore: (DataDirItem) -> Void
    let onManageExistingLink: (DataDirItem) -> Void
    let onNormalizeManagedLink: (DataDirItem) -> Void
    let onRelinkExternalData: (DataDirItem) -> Void
    /// 挂载迁移相关操作（仅应用数据页的沙盒应用容器项使用）
    var onMountMigrate: ((DataDirItem) -> Void)? = nil
    var onMount: ((DataDirItem) -> Void)? = nil
    var onUnmount: ((DataDirItem) -> Void)? = nil
    var onMountRestore: ((DataDirItem) -> Void)? = nil
    /// 经典模式：容器目录同时提供符号链接「迁移」
    var classicModeActive: Bool = false
    /// 行内保留全部直接操作，次要操作使用图标以节省名称空间。
    var inline = false

    @ViewBuilder
    var body: some View {
        if DataDirStatus.mountStatuses.contains(item.status) {
            mountOperationButtons
        } else if item.canRestore && (!item.isMigratable || item.status != DataDirStatus.needsNormalization) {
            restoreButton()
        } else if !item.isMigratable {
            // 不可迁移的目录：显示禁用按钮 + tooltip
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.5))
                .help((item.nonMigratableReason ?? "此目录不支持迁移").localized)
        } else if item.status == "待规范" {
            if item.linkedDestination != nil {
                Button(action: { onNormalizeManagedLink(item) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("整理".localized)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, inline ? 8 : 10)
                    .padding(.vertical, inline ? 7 : 5)
                    .background(
                        Capsule().fill(Color.mint)
                    )
                }
                .buttonStyle(.plain)
                .help("将已接管的链接整理到 AppPorts 规范路径".localized)
            }
            // A legacy managed link can always be restored without first normalizing it.
            // Keep the secondary action compact inside the browser's fixed-width column.
            if item.canRestore { restoreButton(compact: inline) }
        } else if item.status == "现有软链" {
            if item.linkedDestination != nil {
                Button(action: { onManageExistingLink(item) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        Text("链接详情".localized)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, inline ? 8 : 10)
                    .padding(.vertical, inline ? 7 : 5)
                    .background(
                        Capsule().fill(Color.teal)
                    )
                }
                .buttonStyle(.plain)
                .help("查看现有软链路径，并可将其纳入 AppPorts 管理".localized)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.teal.opacity(0.85))
                    .help("检测到已有符号链接，非 AppPorts 迁移结果".localized)
            }
        } else if item.status == "待接回" {
            if item.linkedDestination != nil {
                Button(action: { onRelinkExternalData(item) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                        Text("接回".localized)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, inline ? 8 : 10)
                    .padding(.vertical, inline ? 7 : 5)
                    .background(
                        Capsule().fill(Color.indigo)
                    )
                }
                .buttonStyle(.plain)
                .help("外部目录已存在，在原路径补建符号链接".localized)
            }
        } else if item.status == "本地" {
            if item.requiresMountMigration, let onMountMigrate {
                // 容器数据：挂载迁移；经典模式下额外提供符号链接迁移
                if classicModeActive {
                    Button(action: { onMigrate(item) }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right.circle")
                            if !inline { Text("迁移".localized) }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, inline ? 8 : 10)
                        .padding(.vertical, inline ? 7 : 5)
                        .background(Capsule().stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("迁移".localized)
                    .help("经典模式：用符号链接迁移（不推荐）".localized)
                }
                Button(action: { onMountMigrate(item) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "externaldrive.fill.badge.plus")
                        Text(classicModeActive ? "挂载迁移".localized : "迁移".localized)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, inline ? 8 : 10)
                    .padding(.vertical, inline ? 7 : 5)
                    .background(
                        Capsule().fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
                .help("在外部存储上创建 APFS 卷并挂载到此目录（实验性）".localized)
            } else if item.requiresMountMigration {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.5))
                    .help("沙盒应用的容器数据不支持符号链接迁移".localized)
            } else {
                // 本地：显示「迁移」按钮
                Button(action: { onMigrate(item) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("迁移".localized)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, inline ? 8 : 10)
                    .padding(.vertical, inline ? 7 : 5)
                    .background(
                        Capsule().fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
                .help("将数据目录迁移到外部存储".localized)
            }
        }
    }

    private func restoreButton(compact: Bool = false) -> some View {
        Button(action: { onRestore(item) }) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                if !compact { Text("还原".localized) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, inline ? 8 : 10)
            .padding(.vertical, inline ? 7 : 5)
            .background(Capsule().fill(Color.orange))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("还原".localized)
        .help("将数据目录还原到本地".localized)
    }

    /// 挂载迁移项：已挂载可卸载/还原，待挂载可挂载/还原，外置盘未连接时只提示。
    @ViewBuilder
    private var mountOperationButtons: some View {
        HStack(spacing: 6) {
            if item.status == DataDirStatus.mounted, let onUnmount {
                Button(action: { onUnmount(item) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "eject.fill")
                            .font(.system(size: inline ? 14 : 12))
                        if !inline { Text("卸载".localized) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, inline ? 8 : 10)
                    .padding(.vertical, inline ? 7 : 5)
                    .background(Capsule().fill(Color.gray))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("卸载".localized)
                .help("卸载外置卷。卸载后应用会看到空目录，请在拔盘前先退出应用".localized)
            } else if item.status == DataDirStatus.pendingMount, let onMount {
                Button(action: { onMount(item) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .font(.system(size: inline ? 14 : 12))
                        if !inline { Text("挂载".localized) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, inline ? 8 : 10)
                    .padding(.vertical, inline ? 7 : 5)
                    .background(Capsule().fill(Color.purple))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("挂载".localized)
                .help("把外置卷重新挂载到此目录".localized)
            }

            if item.status == DataDirStatus.volumeMissing {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 13))
                    .foregroundColor(.red.opacity(0.8))
                    .help("外置盘未连接。连接这块外部存储后会自动接回；如果已经连接仍显示此状态，数据卷可能被改名或删除，请查看挂载迁移文档里的排查步骤".localized)
            } else if let onMountRestore {
                Button(action: { onMountRestore(item) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                        Text("还原".localized)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, inline ? 8 : 10)
                    .padding(.vertical, inline ? 7 : 5)
                    .background(Capsule().fill(Color.orange))
                }
                .buttonStyle(.plain)
                .help("将数据目录还原到本地".localized)
            }
        }
    }

}

// MARK: - 优先级标签

struct PriorityBadge: View {
    let priority: DataDirPriority

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(priority.localizedTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
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
    var compact = true
    var isEmphasized = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .font(.system(size: compact ? 8 : 10))
            Text(DataDirStatus.localized(status))
                .font(.system(size: compact ? 10 : 11, weight: .medium))
        }
        .foregroundColor(isEmphasized ? .white : foregroundColor)
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(isEmphasized ? Color.white.opacity(0.16) : backgroundColor)
        .clipShape(Capsule())
    }

    private var statusIcon: String {
        switch status {
        case "已链接": return "link"
        case "待规范": return "arrow.triangle.2.circlepath"
        case "现有软链": return "questionmark.circle"
        case "用户目录入口": return "link"
        case "待接回": return "arrow.triangle.branch"
        case "本地":   return "internaldrive"
        case "已挂载": return "externaldrive.fill.badge.checkmark"
        case "待挂载": return "externaldrive.badge.plus"
        case "卷丢失": return "externaldrive.badge.xmark"
        default:       return "questionmark"
        }
    }

    private var foregroundColor: Color {
        switch status {
        case "已链接": return .green
        case "待规范": return .mint
        case "现有软链": return .teal
        case "待接回": return .indigo
        case "本地":   return .secondary
        case "已挂载": return .purple
        case "待挂载": return .orange
        case "卷丢失": return .red
        default:       return .gray
        }
    }

    private var backgroundColor: Color {
        switch status {
        case "已链接": return .green.opacity(0.12)
        case "待规范": return .mint.opacity(0.14)
        case "现有软链": return .teal.opacity(0.14)
        case "待接回": return .indigo.opacity(0.14)
        case "本地":   return Color.primary.opacity(0.05)
        case "已挂载": return .purple.opacity(0.12)
        case "待挂载": return .orange.opacity(0.14)
        case "卷丢失": return .red.opacity(0.12)
        default:       return .gray.opacity(0.08)
        }
    }
}
