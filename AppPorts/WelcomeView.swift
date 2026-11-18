//
//  WelcomeView.swift
//  AppPort
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI

// MARK: - 欢迎界面

/// 两屏式欢迎界面。
///
/// 两屏共用同一套骨架，保证视觉一致：
/// 顶部同一个英雄镜头图标 + 标题副标题，中间是设置页风格的卡片，底部是同一个操作栏。
/// - 第一屏：介绍三大能力
/// - 第二屏：准备情况（权限与外部存储格式）
///
/// 走完一次后写入 `completionDefaultsKey`，之后不再自动出现；需要重新检查时去「设置」。
struct WelcomeView: View {
    /// 完成欢迎屏后写入的键
    static let completionDefaultsKey = "welcomeCompleted"

    /// 控制欢迎界面显示/隐藏的绑定变量
    @Binding var showWelcomeScreen: Bool

    /// 语言管理器，用于多语言切换
    @ObservedObject private var languageManager = LanguageManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 走完欢迎屏后置为 true，之后不再自动出现
    @AppStorage(WelcomeView.completionDefaultsKey) private var welcomeCompleted = false

    /// 当前是第几屏（0：介绍，1：准备情况）
    @State private var step = 0

    /// 首屏内容是否已入场
    @State private var contentIn = false

    /// 居中内容列的宽度上限。
    ///
    /// 欢迎屏和主界面共用同一个窗口，主界面最小宽度是 900，所以这里不跟着窗口变宽。
    /// 这个值是按文案长度定的：卡片里最长的一行说明用 `.caption` 排出来约 330pt，
    /// 加上右侧图标徽标和内边距正好填满，卡片里不会留出一条空白。
    private let contentMaxWidth: CGFloat = 420

    private let stepCount = 2

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    stepContent
                        .padding(.top, 30)
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 36)
                .padding(.top, 36)
                .padding(.bottom, 28)
            }

            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .overlay(alignment: .topTrailing) {
            LanguageSwitcher(languageManager: languageManager)
                .padding(18)
                .opacity(contentIn ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.5), value: contentIn)
        }
        .onAppear {
            contentIn = true
        }
    }

    // MARK: - 顶部（两屏共用）

    private var header: some View {
        VStack(spacing: 16) {
            HeroIcon()

            // 两屏的标题副标题叠在一起交叉淡入淡出，避免文案切换时整体跳动。
            ZStack {
                stepCaption(
                    title: "欢迎使用 AppPorts".localized,
                    subtitle: "您的应用，随处安家。".localized
                )
                .opacity(step == 0 ? 1 : 0)

                stepCaption(
                    title: "准备情况".localized,
                    subtitle: "AppPorts 需要这些权限才能迁移应用，外部存储建议使用 APFS 格式。".localized
                )
                .opacity(step == 1 ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: step)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .opacity(contentIn ? 1 : 0)
        .offset(y: (contentIn || reduceMotion) ? 0 : 10)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.55).delay(0.15), value: contentIn)
    }

    private func stepCaption(title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text(subtitle)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 内容（两屏同一种卡片）

    @ViewBuilder
    private var stepContent: some View {
        Group {
            if step == 0 {
                introCards
            } else {
                readinessCards
            }
        }
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: step)
        .opacity(contentIn ? 1 : 0)
        .offset(y: (contentIn || reduceMotion) ? 0 : 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.34), value: contentIn)
    }

    private var introCards: some View {
        VStack(spacing: 12) {
            FeatureCard(
                icon: "externaldrive.fill.badge.plus",
                color: .orange,
                title: "应用瘦身".localized,
                detail: "将庞大的应用程序一键迁移至外部移动硬盘，释放宝贵的 Mac 本地空间。".localized
            )

            FeatureCard(
                icon: "link",
                color: .green,
                title: "无感链接".localized,
                detail: "在原位置自动创建符号链接，系统和 Launchpad 依然能正常识别应用。".localized
            )

            FeatureCard(
                icon: "arrow.uturn.backward.circle.fill",
                color: .blue,
                title: "随时还原".localized,
                detail: "需要时，可随时将应用一键完整迁回本地 /Applications 目录。".localized
            )
        }
    }

    private var readinessCards: some View {
        // 与首屏一样，卡片紧贴标题下方开始；刷新入口和脚注并成一行放在卡片下方，
        // 不额外占用卡片上方的空间，两屏的卡片就落在同一条水平线上。
        ReadinessCheckView(
            refreshPlacement: .bottom,
            footnote: "完成后可在「设置」中重新检查".localized
        )
    }

    // MARK: - 底部操作栏（两屏共用）

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                pageIndicator

                Spacer(minLength: 0)

                if step > 0 {
                    Button(action: goBack) {
                        Text("上一步".localized)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                Button(action: advance) {
                    HStack(spacing: 6) {
                        Text(step == stepCount - 1 ? "开始使用".localized : "继续".localized)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(.bar)
        .opacity(contentIn ? 1 : 0)
        .offset(y: (contentIn || reduceMotion) ? 0 : 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.44), value: contentIn)
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index == step ? Color.primary.opacity(0.55) : Color.primary.opacity(0.15))
                    .frame(width: index == step ? 16 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
    }

    // MARK: - 行为

    private func advance() {
        guard step < stepCount - 1 else {
            finish()
            return
        }
        if reduceMotion {
            step += 1
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                step += 1
            }
        }
    }

    private func goBack() {
        if reduceMotion {
            step -= 1
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                step -= 1
            }
        }
    }

    private func finish() {
        welcomeCompleted = true
        if reduceMotion {
            showWelcomeScreen = false
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                showWelcomeScreen = false
            }
        }
    }
}

// MARK: - 组件

/// 首屏的一张能力卡片。
///
/// 文案在左、图标徽标在右，左右各有一个落点，卡片不会被拉成左重右空的一条；
/// 卡片外壳和「准备情况」用的是同一套 `settingsCardBackground()`，两屏观感保持一致。
private struct FeatureCard: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.15))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(color)
                }
                .accessibilityHidden(true)
        }
        .settingsCardBackground()
    }
}

/// 首屏的英雄镜头：图标落位后带光晕呼吸、缓慢漂浮，并划过一道高光。
/// 两屏共用同一个实例，切换步骤时不会重新播放。
private struct HeroIcon: View {
    private let size: CGFloat = 84
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var glowExpanded = false
    @State private var floating = false
    @State private var shineOffset: CGFloat = -70
    @State private var shineOpacity: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(0.28),
                            Color.accentColor.opacity(0)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.76
                    )
                )
                .frame(width: size * 1.9, height: size * 1.9)
                .scaleEffect(glowExpanded ? 1.1 : 0.88)
                .blur(radius: 6)

            iconImage
                .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 10)
                .overlay(shine)
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .scaleEffect((appeared || reduceMotion) ? 1 : 0.7)
        .opacity((appeared || reduceMotion) ? 1 : 0)
        .blur(radius: (appeared || reduceMotion) ? 0 : 14)
        .offset(y: ((appeared || reduceMotion) ? 0 : 18) + (floating ? -5 : 0))
        .onAppear(perform: start)
    }

    private var iconImage: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    /// 斜向划过图标表面的高光，被图标自身的轮廓裁切。
    private var shine: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.55),
                        Color.white.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 36, height: size * 1.6)
            .rotationEffect(.degrees(22))
            .offset(x: shineOffset)
            .opacity(shineOpacity)
            .blendMode(.plusLighter)
            .mask(iconImage)
    }

    private func start() {
        if reduceMotion {
            appeared = true
            return
        }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) {
            appeared = true
        }
        withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true).delay(0.8)) {
            glowExpanded = true
        }
        withAnimation(.easeInOut(duration: 4.6).repeatForever(autoreverses: true).delay(0.9)) {
            floating = true
        }
        withAnimation(.easeOut(duration: 1.05).delay(0.42)) {
            shineOpacity = 1
            shineOffset = size * 0.9
        }
        withAnimation(.easeOut(duration: 0.5).delay(1.5)) {
            shineOpacity = 0
        }
    }
}

// MARK: - 语言切换

struct LanguageSwitcher: View {
    @ObservedObject var languageManager: LanguageManager
    @ObservedObject private var operationState = AppOperationState.shared
    
    var body: some View {
        Menu {
            Button(AppLanguageCatalog.systemOptionTitle) {
                withAnimation { languageManager.language = "system" }
            }
            
            ForEach(AppLanguageCatalog.primaryLanguages) { option in
                Button(option.menuTitle) {
                    withAnimation { languageManager.language = option.code }
                }
            }
            
            Divider()
            Section(AppLanguageCatalog.aiSectionTitle) {
                ForEach(AppLanguageCatalog.aiTranslatedLanguages) { option in
                    Button(option.menuTitle) {
                        withAnimation { languageManager.language = option.code }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLanguageFlag).font(.subheadline)
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
        .disabled(operationState.isBusy)
    }
    
    var currentLanguageOption: AppLanguageOption? {
        AppLanguageCatalog.option(for: languageManager.language)
    }

    var currentLanguageFlag: String {
        currentLanguageOption?.flag ?? "🌐"
    }

    var currentLanguageName: String {
        currentLanguageOption?.selectionTitle ?? AppLanguageCatalog.automaticSelectionTitle
    }
}
