//
//  AboutView.swift
//  AppMover
//
//  Created by 王恒 on 2025/11/18.
//

import SwiftUI

struct AboutView: View {
    // 这个环境值用来“关闭”这个弹窗
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("AppMover")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Version 1.0.0")
                .font(.caption)
                .foregroundColor(.gray)
            
            Divider()
            
            // --- 在这里填写您的个人信息 ---
            Text("开发者：Hanoch4869")
                .font(.headline)
            
            Text("感谢你使用本工具，尿袋拯救世界！")
                .font(.body)
            
            // 您可以把 "my-website-link" 换成您的真实网址
            // Link 会自动创建可点击的链接
            Link("我的个人网站", destination: URL(string: "https://www.shimoko.com")!)
            Link("项目地址", destination: URL(string: "https://github.com/wzh4869")!)
            
            // --- 结束 ---
            
            Spacer()
            
            Button("关闭") {
                dismiss() // 点击按钮时，关闭这个窗口
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(width: 300, height: 280) // 固定的“关于”窗口大小
    }
}
