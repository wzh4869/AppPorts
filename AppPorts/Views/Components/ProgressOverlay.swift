//
//  ProgressOverlay.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI

/// 迁移进度弹窗
struct ProgressOverlay: View {
    let current: Int
    let total: Int
    let appName: String
    let copiedBytes: Int64
    let totalBytes: Int64
    
    var body: some View {
        VStack(spacing: 16) {
            Text("正在迁移应用...")
                .font(.headline)
            
            // 批量迁移时显示应用进度
            if total > 1 {
                Text("应用 \(current) / \(total)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(appName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
            
            // 单应用字节级进度条
            ProgressView(value: Double(copiedBytes), total: Double(max(totalBytes, 1)))
                .progressViewStyle(.linear)
                .frame(width: 300)
            
            // 显示已复制/总大小
            Text(formatProgress(copiedBytes: copiedBytes, totalBytes: totalBytes))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(32)
        .background(.regularMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    private func formatProgress(copiedBytes: Int64, totalBytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        if totalBytes == 0 {
            return "计算中..."
        }
        return "\(formatter.string(fromByteCount: copiedBytes)) / \(formatter.string(fromByteCount: totalBytes))"
    }
}
