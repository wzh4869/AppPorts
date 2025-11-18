//
//  AboutView.swift
//  AppPort
//
//  Created by shimoko.com on 2025/11/19.
//

import SwiftUI

struct AboutView: View {
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            
            // 1. LOGO 区域
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue, Color.purple]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            .overlay(
                Image(systemName: "box.truck.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .symbolEffect(.pulse, options: .repeating)
            )
            .padding(.top, 35)
            .padding(.bottom, 15)
            
            // 2. 文字信息
            VStack(spacing: 6) {
                Text("AppPorts")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Version 1.0.0")
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

struct LinkButton: View {
    let titleKey: LocalizedStringKey
    let icon: String
    let url: String
    
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
