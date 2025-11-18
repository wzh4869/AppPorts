//
//  WelcomeView.swift
//  AppMover
//
//  Created by Hanoch4869 on 2025/11/18.
//
import SwiftUI

struct WelcomeView: View {
    // 这个 @Binding 允许我们告诉主应用 "我被点击了"
    @Binding var showWelcomeScreen: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            // 您可以把 `AppIcon` 换成您自己的图标
            Image(systemName: "archivebox.circle.fill")
                .font(.system(size: 100))
                .foregroundColor(.blue)
            
            Text("欢迎使用 AppPort")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("一个帮您迁移 Mac 应用到移动硬盘\n并创建符号链接的小工具。")
                .font(.title3)
                .multilineTextAlignment(.center) // 居中对齐
                .foregroundColor(.gray)
            
            Text("重要提示：\n首次使用时，本应用 或许需要“完全磁盘访问”权限\n才能读写 /Applications 目录。")
                .font(.caption)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            
            Button("我已了解，开始使用 ➔") {
                // 点击按钮时，将这个值设为 false，主应用会检测到
                self.showWelcomeScreen = false
            }
            .buttonStyle(.borderedProminent) // 好看的大按钮样式
            .controlSize(.large) // 大号按钮
        }
        .padding(40)
        .frame(width: 500, height: 450) // 固定窗口大小
    }
}
