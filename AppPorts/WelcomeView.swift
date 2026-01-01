//
//  WelcomeView.swift
//  AppPort
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI

struct WelcomeView: View {
    @Binding var showWelcomeScreen: Bool
    
    // 语言管理器，以便修改语言设置
    @ObservedObject private var languageManager = LanguageManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            
            //顶部 Header区域
            VStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                
                Text("欢迎使用 AppPorts") // Key
                    .font(.system(size: 28, weight: .bold))
            }
            .padding(.top, 50)
            .padding(.bottom, 30)
            
            // 功能特性列表
            VStack(alignment: .leading, spacing: 28) {
                FeatureRow(
                    icon: "externaldrive.fill.badge.plus",
                    color: .orange,
                    titleKey: "应用瘦身",
                    descriptionKey: "将庞大的应用程序一键迁移至外部移动硬盘，释放宝贵的 Mac 本地空间。"
                )
                
                FeatureRow(
                    icon: "link",
                    color: .green,
                    titleKey: "无感链接",
                    descriptionKey: "在原位置自动创建符号链接，系统和 Launchpad 依然能正常识别应用。"
                )
                
                FeatureRow(
                    icon: "arrow.uturn.backward.circle.fill",
                    color: .blue,
                    titleKey: "随时还原",
                    descriptionKey: "需要时，可随时将应用一键完整迁回本地 /Applications 目录。"
                )
            }
            .padding(.horizontal, 50)
            
            Spacer()
            
            // 底部区域 (权限引导和按钮)
            VStack(spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title2)
                        .foregroundColor(Color(nsColor: .systemOrange))
                        .padding(.top, 2)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("需要“完全磁盘访问权限”") // Key
                            .font(.headline)
                            .fontDesign(.rounded)
                            .foregroundColor(.primary)
                        
                        Text("应用需要读写 /Applications 目录才能工作。请在系统设置中开启。") // Key
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Button(action: openFullDiskAccessSettings) {
                            HStack(spacing: 4) {
                                Text("去设置授予权限") // Key
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10))
                            }
                            .font(.caption)
                            .fontWeight(.semibold)
                        }
                        .buttonStyle(.link)
                        .padding(.top, 4)
                    }
                }
                .padding(16)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.15), lineWidth: 1)
                )
                
                Button(action: {
                    withAnimation {
                        self.showWelcomeScreen = false
                    }
                }) {
                    Text("我已授权，开始使用") // Key
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 50)
        }
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        
        // overlay 在右上角添加语言切换按钮
        .overlay(alignment: .topTrailing) {
            LanguageSwitcher(languageManager: languageManager)
                .padding(20) //距离右上角的边距
        }
    }
    
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

//语言切换器 ---
struct LanguageSwitcher: View {
    @ObservedObject var languageManager: LanguageManager
    
    var body: some View {
        Menu {

            Button("跟随系统 (System)") {
                withAnimation { languageManager.language = "system" }
            }
            Button("English") {
                withAnimation { languageManager.language = "en" }
            }
            Button("简体中文") {
                withAnimation { languageManager.language = "zh-Hans" }
            }
        } label: {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundColor(.secondary)
                .padding(8)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
        .menuStyle(.borderlessButton) 
        .help("Change Language / 切换语言")
    }
}

// --- 辅助视图组件：功能行 ---
struct FeatureRow: View {
    let icon: String
    let color: Color
    let titleKey: LocalizedStringKey
    let descriptionKey: LocalizedStringKey
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(color)
                .frame(width: 32)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(titleKey)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text(descriptionKey)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }
}

#Preview {
    WelcomeView(showWelcomeScreen: .constant(true))
        .frame(width: 600, height: 750)
}
