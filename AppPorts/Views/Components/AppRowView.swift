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
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 14) {
            AppIconView(url: app.path)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                HStack(spacing: 8) {
                    StatusBadge(app: app)
                    
                    if let size = app.size {
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    } else {
                        Text("计算中...".localized)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                            .transition(.opacity)
                    }
                }
            }
            
            Spacer()
            
            if showDeleteLinkButton && app.status == "已链接" {
                Button(action: { onDeleteLink(app) }) {
                    Image(systemName: "link.badge.plus")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.red.opacity(0.1))
                .clipShape(Circle())
                .help("断开此链接并删除文件".localized)
            }
            
            if showMoveBackButton {
                Button(action: { onMoveBack(app) }) {
                    Image(systemName: "arrow.uturn.backward")
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.blue.opacity(0.1))
                .clipShape(Circle())
                .help("将应用迁移回本地".localized)
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
                self.isHovered = hovering
            }
        }
        // Accessibility: Combine row into single element
        .accessibilityElement(children: .combine)
        // Custom Actions for VoiceOver (Swipe up/down)
        .accessibilityActions {
             if showDeleteLinkButton && app.status == "已链接" {
                 Button(action: { onDeleteLink(app) }) {
                     Text("断开".localized)
                 }
             }
             
             if showMoveBackButton {
                 Button(action: { onMoveBack(app) }) {
                     Text("还原".localized)
                 }
             }
             
             Button(action: {
                 NSWorkspace.shared.activateFileViewerSelecting([app.path])
             }) {
                 Text("在 Finder 中显示".localized)
             }
        }
        .contextMenu {
            Button("在 Finder 中显示".localized) {
                NSWorkspace.shared.activateFileViewerSelecting([app.path])
            }
        }
    }
}
