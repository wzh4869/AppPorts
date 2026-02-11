//
//  AboutView.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/19.
//

import SwiftUI

// MARK: - 关于界面

/// 应用的"关于"弹窗界面
///
/// 展示应用的基本信息和相关链接：
/// - 🖼 应用图标和名称
/// - 📌 当前版本号
/// - 💬 感谢文案
/// - 🔗 个人网站和 GitHub 项目链接
///
/// ## 界面尺寸
/// 固定尺寸：380 x 480 点
///
/// ## 使用方式
/// 通过应用菜单栏的"关于"选项打开此弹窗
///
/// - Note: 使用 SwiftUI Environment 的 dismiss 关闭弹窗
struct AboutView: View {
    /// 环境变量：用于关闭弹窗
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            
            // 1. LOGO 区域
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            .padding(.top, 35)
            .padding(.bottom, 15)
            
            // 2. 文字信息
            VStack(spacing: 6) {
                Text("AppPorts")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 8)
            
            // 3. 描述文案
            Text("感谢你使用本工具，外置硬盘拯救世界！")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary.opacity(0.9))
                .padding(.horizontal)
                .padding(.bottom, 20)
            
            // 4. 链接区域 (垂直排列)
            VStack(spacing: 12) {
                LinkButton(
                    titleKey: "个人网站",
                    icon: "globe",
                    url: "https://www.shimoko.com"
                )
                

                LinkButton(
                    titleKey: "项目地址",
                    icon: "terminal.fill",
                    url: "https://github.com/wzh4869/AppPorts"
                )
            }
            .padding(.horizontal, 40)
            
            Spacer()
            
            // 5. 关闭按钮
            Button("关闭") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 30)
            
        }
        .padding(30)
        .frame(width: 380, height: 480)
    }
}

// MARK: - 链接按钮组件

/// 外部链接按钮组件
///
/// 带有图标和悬停效果的链接按钮，用于跳转到外部网页。
///
/// ## 设计特点
/// - 左侧：图标
/// - 中间：链接文本
/// - 右侧：外部链接箭头
/// - 悬停时：背景颜色加深
///
/// - Note: 使用 SwiftUI Link 组件，点击自动在浏览器打开
struct LinkButton: View {
    /// 按钮显示文本（本地化字符串键）
    let titleKey: LocalizedStringKey
    
    /// SF Symbols 图标名称
    let icon: String
    
    /// 跳转的目标 URL
    let url: String
    
    /// 是否处于悬停状态
    @State private var isHovering = false
    
    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                
                Text(titleKey)
                    .fontWeight(.medium)
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .opacity(0.5)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hover
            }
        }
    }
}

#Preview {
    AboutView()
}
