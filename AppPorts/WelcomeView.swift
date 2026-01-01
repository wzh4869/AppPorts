//
//  WelcomeView.swift
//  AppPort
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI

struct WelcomeView: View {
    @Binding var showWelcomeScreen: Bool
    @ObservedObject private var languageManager = LanguageManager.shared
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            // MARK: - Ambient Background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.blue.opacity(0.05),
                    Color.orange.opacity(0.05)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // MARK: - Header Section
                VStack(spacing: 20) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 110, height: 110)
                        .shadow(color: .black.opacity(0.1), radius: 12, x: 0, y: 6)
                        .scaleEffect(isAnimating ? 1 : 0.9)
                        .opacity(isAnimating ? 1 : 0)
                        
                    VStack(spacing: 8) {
                        Text("欢迎使用 AppPorts")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.primary, .primary.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        
                        Text("您的应用，随处安家。") // New Key needed, or reuse generic
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .offset(y: isAnimating ? 0 : 10)
                    .opacity(isAnimating ? 1 : 0)
                }
                .padding(.top, 40)
                .padding(.bottom, 40)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                
                // MARK: - Features List
                VStack(alignment: .leading, spacing: 20) {
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
                .padding(.horizontal, 40)
                .offset(y: isAnimating ? 0 : 20)
                .opacity(isAnimating ? 1 : 0)
                
                Spacer()
                
                // MARK: - Permission & Action
                VStack(spacing: 24) {
                    // Permission Card
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "lock.shield.fill")
                            .font(.title2)
                            .foregroundColor(.orange)
                            .padding(.top, 2)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("需要“完全磁盘访问权限”")
                                .font(.headline)
                                .fontDesign(.rounded)
                                .foregroundColor(.primary)
                            
                            Text("应用需要读写 /Applications 目录才能工作。请在系统设置中开启。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            Button(action: openFullDiskAccessSettings) {
                                HStack(spacing: 4) {
                                    Text("去设置授予权限")
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10))
                                }
                                .font(.caption)
                                .fontWeight(.semibold)
                            }
                            .buttonStyle(.link)
                            .padding(.top, 2)
                        }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("双击打开系统设置")
                    
                    // Main CTA
                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            self.showWelcomeScreen = false
                        }
                    }) {
                        HStack {
                            Text("我已授权，开始使用")
                            Image(systemName: "arrow.right")
                        }
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.large)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
                .offset(y: isAnimating ? 0 : 30)
                .opacity(isAnimating ? 1 : 0)
            }
        }
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 750, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            LanguageSwitcher(languageManager: languageManager)
                .padding(20)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                isAnimating = true
            }
        }
    }
    
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Components

struct LanguageSwitcher: View {
    @ObservedObject var languageManager: LanguageManager
    
    var body: some View {
        Menu {
            Button("跟随系统 (System)") { withAnimation { languageManager.language = "system" } }
            
            Group {
                Button("🇺🇸 English") { withAnimation { languageManager.language = "en" } }
                Button("🇨🇳 简体中文") { withAnimation { languageManager.language = "zh-Hans" } }
                Button("🇭🇰 繁體中文") { withAnimation { languageManager.language = "zh-Hant" } }
            }
            
            Divider()
            Section("AI Translated") {
                Button("🇪🇸 Español") { withAnimation { languageManager.language = "es" } }
                Button("🇫🇷 Français") { withAnimation { languageManager.language = "fr" } }
                Button("🇩🇪 Deutsch") { withAnimation { languageManager.language = "de" } }
                Button("🇮🇹 Italiano") { withAnimation { languageManager.language = "it" } }
                Button("🇵🇹 Português") { withAnimation { languageManager.language = "pt" } }
                Button("🇷🇺 Русский") { withAnimation { languageManager.language = "ru" } }
                Button("🇯🇵 日本語") { withAnimation { languageManager.language = "ja" } }
                Button("🇰🇷 한국어") { withAnimation { languageManager.language = "ko" } }
                Button("🇻🇳 Tiếng Việt") { withAnimation { languageManager.language = "vi" } }
                Button("🇹🇭 ไทย") { withAnimation { languageManager.language = "th" } }
                Button("🇹🇷 Türkçe") { withAnimation { languageManager.language = "tr" } }
                Button("🇳🇱 Nederlands") { withAnimation { languageManager.language = "nl" } }
                Button("🇵🇱 Polski") { withAnimation { languageManager.language = "pl" } }
                Button("🇮🇩 Indonesia") { withAnimation { languageManager.language = "id" } }
                Button("🇸🇦 العربية") { withAnimation { languageManager.language = "ar" } }
                Button("🇮🇳 हिन्दी") { withAnimation { languageManager.language = "hi" } }
                Button("🏁 Esperanto") { withAnimation { languageManager.language = "eo" } }
                Button("⠃⠗ Braille") { withAnimation { languageManager.language = "br" } }
            }
        } label: {
            HStack(spacing: 6) {
                // Determine flag based on language
                let flag: String = {
                    switch languageManager.language {
                    case "en": return "🇺🇸"
                    case "zh-Hans": return "🇨🇳"
                    case "zh-Hant": return "🇭🇰"
                    case "es": return "🇪🇸"
                    case "fr": return "🇫🇷"
                    case "de": return "🇩🇪"
                    case "it": return "🇮🇹"
                    case "pt": return "🇵🇹"
                    case "ru": return "🇷🇺"
                    case "ja": return "🇯🇵"
                    case "ko": return "🇰🇷"
                    case "vi": return "🇻🇳"
                    case "th": return "🇹🇭"
                    case "tr": return "🇹🇷"
                    case "nl": return "🇳🇱"
                    case "pl": return "🇵🇱"
                    case "id": return "🇮🇩"
                    case "ar": return "🇸🇦"
                    case "hi": return "🇮🇳"
                    case "eo": return "🏁"
                    case "br": return "⠃⠗"
                    default: return "🌐"
                    }
                }()
                
                Text(flag).font(.subheadline)
                Text(currentLanguageName)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        .menuStyle(.borderlessButton)
        .focusable(false)
    }
    
    var currentLanguageName: String {
        switch languageManager.language {
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "es": return "Español (AI)"
        case "fr": return "Français (AI)"
        case "de": return "Deutsch (AI)"
        case "it": return "Italiano (AI)"
        case "pt": return "Português (AI)"
        case "ru": return "Русский (AI)"
        case "ja": return "日本語 (AI)"
        case "ko": return "한국어 (AI)"
        case "vi": return "Tiếng Việt (AI)"
        case "th": return "ไทย (AI)"
        case "tr": return "Türkçe (AI)"
        case "nl": return "Nederlands (AI)"
        case "pl": return "Polski (AI)"
        case "id": return "Indonesia (AI)"
        case "ar": return "العربية (AI)"
        case "hi": return "हिन्दी (AI)"
        case "eo": return "Esperanto (AI)"
        case "br": return "Braille (⠃⠗)"
        default: return "Auto"
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let color: Color
    let titleKey: LocalizedStringKey
    let descriptionKey: LocalizedStringKey
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.1))
                    .frame(width: 44, height: 44)
                
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(titleKey)
                    .font(.headline)
                    .fontDesign(.rounded)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text(descriptionKey)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        )
        .onHover { mirroring in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = mirroring
            }
        }
        .accessibilityElement(children: .combine)
    }
}
