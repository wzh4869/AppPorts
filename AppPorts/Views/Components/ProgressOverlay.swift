//
//  ProgressOverlay.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI

// MARK: - 迁移进度覆盖层

/// 应用迁移进度弹窗
///
/// 在应用迁移过程中显示的模态进度指示器。提供实时反馈：
/// - 当前迁移的应用名称
/// - 批量迁移时的应用计数（如 "应用 2 / 5"）
/// - 字节级复制进度条
/// - 已复制/总大小的可读格式显示
///
/// ## 视觉设计
/// - 使用半透明材质背景（`.regularMaterial`）
/// - 圆角设计（16px）+ 阴影效果
/// - 等宽数字字体显示进度数据
///
/// ## 使用场景
/// - 单个应用迁移：显示应用名和复制进度
/// - 批量迁移：额外显示 "应用 X / Y"
///
/// - Note: 进度条宽度固定为 300 点，适合大部分情况
struct ProgressOverlay: View {
    /// 当前迁移的应用索引（从 1 开始）
    let current: Int
    
    /// 总共要迁移的应用数量
    let total: Int
    
    /// 当前迁移的应用名称
    let appName: String
    
    /// 已复制的字节数
    let copiedBytes: Int64
    
    /// 总字节数
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
    
    /// 格式化进度信息
    ///
    /// 将字节数转换为人类可读的格式（MB/GB）
    ///
    /// - Parameters:
    ///   - copiedBytes: 已复制的字节数
    ///   - totalBytes: 总字节数
    /// - Returns: 格式化后的字符串，如 "1.2 GB / 3.5 GB"
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
