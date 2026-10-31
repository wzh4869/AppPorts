//
//  AppRowView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI
import AppKit

/// 列表行视图
struct AppRowView: View {
    let app: AppItem
    let isSelected: Bool
    let showDeleteLinkButton: Bool
    let showMoveBackButton: Bool
    let onDeleteLink: (AppItem) -> Void
    let onMoveBack: (AppItem) -> Void
    let onResign: ((AppItem) -> Void)?
    let onRestoreSignature: ((AppItem) -> Void)?
    var onMoveOutWholeSymlink: ((AppItem) -> Void)? = nil
    var onRepairDock: ((AppItem) -> Void)? = nil
    /// 签名被替换的应用：打开修复面板
    var onRepairSignature: ((AppItem) -> Void)? = nil
    
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        AppListColumns {
            HStack(spacing: 10) {
                AppIconView(url: app.displayURL, size: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(app.displayName)
                    StatusBadge(app: app, onRepairSignature: onRepairSignature)
                    signatureRepairButton
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } size: {
            Text(app.size ?? "计算中...".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        } actions: {
            rowActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(AppListSelectionAppearance())
        .contentShape(Rectangle())
        // 保留行内按钮，VoiceOver 可以分别选择应用信息和操作。
        .accessibilityElement(children: .contain)
        .contextMenu { appMenuItems }
        .alert("删除本地入口".localized, isPresented: $showDeleteConfirmation) {
            Button("取消".localized, role: .cancel) { }
            Button("直接删除".localized, role: .destructive) { onDeleteLink(app) }
        } message: {
            Text(String(format: "确定删除「%@」的本地入口吗？外部应用文件会保留。".localized, app.displayName))
        }
    }

    private var canDeleteLink: Bool {
        (showDeleteLinkButton && app.status == AppStatus.linked) || app.status == AppStatus.orphanedLink
    }

    private var deleteActionTitle: String {
        app.status == AppStatus.orphanedLink ? "删除孤立链接".localized : "删除本地入口".localized
    }

    @ViewBuilder
    private var appMenuItems: some View {
        Button("在 Finder 中显示".localized) {
            NSWorkspace.shared.activateFileViewerSelecting([app.path])
        }

        if app.status == AppStatus.linked || app.status == AppStatus.partialLinked,
           let onRepairDock {
            Divider()
            Button("修复 Dock 图标".localized) {
                onRepairDock(app)
            }
        }

        if (app.status == AppStatus.local || app.status == AppStatus.pendingMoveOut) && !app.isSystemApp, let onMoveOutWholeSymlink {
            Divider()
            Button("使用传统链接迁移".localized) {
                onMoveOutWholeSymlink(app)
            }
        }

        if app.needsSignatureAttention, let onRepairSignature {
            Divider()
            Button(signatureActionTitle) {
                onRepairSignature(app)
            }
        }

        // A confirmed re-signed installation offers restoration. Unknown
        // history still permits a fresh service inspection before signing.
        if !app.isResigned,
           !app.isFolder,
           !app.isSystemApp,
           app.status != AppStatus.orphanedLink,
           app.displayURL.pathExtension.lowercased() == "app",
           let onResign {
            Divider()
            Button("重签名此应用".localized) {
                onResign(app)
            }
            .disabled(app.isRunning)
        }

        if let onRestoreSignature, app.isResigned || app.signatureCheckUnavailable {
            Divider()
            Button("恢复原始签名".localized) {
                onRestoreSignature(app)
            }
        }

        if showMoveBackButton {
            Divider()
            Button("将应用迁移回本地".localized) { onMoveBack(app) }
        }

        if canDeleteLink {
            Divider()
            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                Text(deleteActionTitle)
            }
        }
    }

    private var signatureActionTitle: String {
        app.signatureCheckUnavailable ? "检查签名".localized : "查看修复步骤".localized
    }

    @ViewBuilder
    private var signatureRepairButton: some View {
        if app.needsSignatureAttention, let onRepairSignature {
            Button(action: { onRepairSignature(app) }) {
                Label(app.signatureCheckUnavailable ? "检查签名".localized : "修复".localized,
                      systemImage: app.signatureCheckUnavailable ? "arrow.clockwise" : "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(signatureActionTitle)
            .help(signatureActionTitle)
        }
    }

    private var rowActions: some View {
        Menu {
            appMenuItems
        } label: {
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

}

