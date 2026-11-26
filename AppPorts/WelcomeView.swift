//
//  WelcomeView.swift
//  AppPort
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI

// MARK: - 欢迎界面

/// 三步式欢迎界面与升级老用户一次性「边界与共识」确认页。
///
/// - `.fullOnboarding`（全新用户）：① 核心能力概览 → ② 边界与共识（勾选确认） → ③ 准备情况
/// - `.boundaryConsensusOnly`（升级老用户）：单屏「边界与共识」（勾选确认一次即进入主界面，不改动 `welcomeCompleted`）
struct WelcomeView: View {
    /// 完成完整欢迎引导后写入的键，供 `LegacyPermissionResetter` 区分新老用户。
    static let completionDefaultsKey = WelcomeLaunchPolicy.welcomeCompletedDefaultsKey

    /// 当前展示形态
    let mode: WelcomePresentationMode

    /// 完成后通知外层切换到主界面
    let onComplete: () -> Void

    /// 语言管理器，用于多语言切换
    @ObservedObject private var languageManager = LanguageManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 当前步骤（`.fullOnboarding`: 0 概览，1 边界与共识，2 准备情况；`.boundaryConsensusOnly`: 固定 0）
    @State private var step = 0

    /// 用户是否已勾选确认边界与数据风险
    @State private var boundaryConsensusAcknowledged = false

    /// 首屏内容是否已入场
    @State private var contentIn = false

    /// 居中内容列宽度上限，兼顾中英文长句阅读节奏与主窗口最小宽度（930pt）。
    private let contentMaxWidth: CGFloat = 620

    private var stepCount: Int {
        mode == .fullOnboarding ? 3 : 1
    }

    private var isBoundaryStep: Bool {
        mode == .boundaryConsensusOnly || step == 1
    }

    private var isHeroStep: Bool {
        mode == .fullOnboarding && step == 0
    }

    private var isPrimaryButtonDisabled: Bool {
        isBoundaryStep && !boundaryConsensusAcknowledged
    }

    var body: some View {
        VStack(spacing: 0) {
            if isBoundaryStep {
                boundaryPageBody
            } else {
                standardPageBody
            }

            actionBar
        }
        .background(AppSurfaceColors.content)
        .frame(
            minWidth: 560,
            idealWidth: 930,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .overlay(alignment: .topTrailing) {
            LanguageSwitcher(languageManager: languageManager)
                .padding(.top, 16)
                .padding(.trailing, 18)
                .opacity(contentIn ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.35), value: contentIn)
        }
        .onAppear {
            contentIn = true
        }
    }

    // MARK: - 边界与共识页（无顶部分隔线，整体流畅排印）

    private var boundaryPageBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
                            .accessibilityHidden(true)

                        Text("关于 AppPorts 的边界与共识".localized)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)
                    }
                    // 右侧为右上角语言切换胶囊预留安全空间，避免窄窗口标题重叠。
                    .padding(.trailing, 120)

                    BoundaryConsensusContentView()
                }
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
        .transition(.opacity)
        .opacity(contentIn ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: contentIn)
    }

    // MARK: - 概览与准备情况页

    private var standardPageBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    standardHeader
                    standardStepContent
                        .padding(.top, isHeroStep ? 26 : 20)
                }
                .frame(maxWidth: contentMaxWidth)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var standardHeader: some View {
        if isHeroStep {
            VStack(spacing: 12) {
                HeroIcon()

                VStack(spacing: 6) {
                    Text("欢迎使用 AppPorts".localized)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("大应用，搬出去。好空间，留给你。".localized)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .opacity(contentIn ? 1 : 0)
            .offset(y: (contentIn || reduceMotion) ? 0 : 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.12), value: contentIn)
        } else {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("准备情况".localized)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("AppPorts 需要这些系统权限才能迁移应用与数据；容器挂载迁移需要 APFS 外部存储。".localized)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.trailing, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var standardStepContent: some View {
        Group {
            if isHeroStep {
                introCards
            } else {
                readinessCards
            }
        }
        .opacity(contentIn ? 1 : 0)
        .offset(y: (contentIn || reduceMotion) ? 0 : 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.48).delay(0.24), value: contentIn)
    }

    private var introCards: some View {
        VStack(spacing: 12) {
            FeatureCard(
                icon: "externaldrive.badge.plus",
                color: BoundaryConsensusStyle.mutedSlateBlue,
                title: "应用迁移与无角标入口".localized,
                detail: "将大型应用迁往外置硬盘或 APFS 应用库映像，本机保留轻量启动壳（Stub Portal），从访达与程序坞照常打开。".localized
            )

            FeatureCard(
                icon: "cylinder.split.1x2",
                color: BoundaryConsensusStyle.mutedTeal,
                title: "容器与数据分离迁移".localized,
                detail: "适用的容器数据默认通过 APFS 挂载迁移，保留应用原始签名；普通数据、开发工具与自选目录按适用条件使用符号链接。".localized
            )

            FeatureCard(
                icon: "arrow.uturn.backward.circle",
                color: BoundaryConsensusStyle.mutedAmber,
                title: "任务中心与随时还原".localized,
                detail: "支持任务排队、暂停与异常恢复；需要时可随时将应用本体或数据完整迁回本机，也可独立接回或解绑本地入口。".localized
            )

            Text("应用本体与数据各自独立管理；外部存储不满足挂载条件时，容器数据可继续留在本机。".localized)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    private var readinessCards: some View {
        ReadinessCheckView(
            refreshPlacement: .bottom,
            footnote: "完成后可在「设置」中重新检查".localized
        )
    }

    // MARK: - 底部操作栏

    private var actionBar: some View {
        VStack(spacing: 12) {
            if isBoundaryStep {
                HStack(spacing: 8) {
                    Toggle(isOn: $boundaryConsensusAcknowledged) {
                        Text("我已阅读并了解以上使用边界与数据风险".localized)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }

            HStack(spacing: 12) {
                if stepCount > 1 {
                    pageIndicator
                } else {
                    Text("确认后将不再重复弹出，可随时在「设置」中重看".localized)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if mode == .fullOnboarding && step > 0 {
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
                        Text(primaryButtonTitle)
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
                .disabled(isPrimaryButtonDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(AppSurfaceColors.content)
        .opacity(contentIn ? 1 : 0)
        .offset(y: (contentIn || reduceMotion) ? 0 : 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.32), value: contentIn)
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .boundaryConsensusOnly:
            return "确认并进入 AppPorts".localized
        case .fullOnboarding:
            return step == stepCount - 1 ? "开始使用".localized : "继续".localized
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index == step ? Color.accentColor : Color.primary.opacity(0.16))
                    .frame(width: index == step ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "%lld / %lld".localized, step + 1, stepCount))
    }

    // MARK: - 行为

    private func advance() {
        guard !isPrimaryButtonDisabled else { return }
        guard step < stepCount - 1 else {
            finish()
            return
        }
        if reduceMotion {
            step += 1
        } else {
            withAnimation(.easeInOut(duration: 0.26)) {
                step += 1
            }
        }
    }

    private func goBack() {
        guard step > 0 else { return }
        if reduceMotion {
            step -= 1
        } else {
            withAnimation(.easeInOut(duration: 0.26)) {
                step -= 1
            }
        }
    }

    private func finish() {
        switch mode {
        case .fullOnboarding:
            WelcomeLaunchPolicy.recordFullOnboardingCompleted()
            AppLogger.shared.log("已完成欢迎引导与边界共识确认")
        case .boundaryConsensusOnly:
            WelcomeLaunchPolicy.recordBoundaryConsensusAcknowledged()
            AppLogger.shared.log("升级老用户已确认边界与共识")
        }

        if reduceMotion {
            onComplete()
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                onComplete()
            }
        }
    }
}

// MARK: - 组件

/// 首屏的一张能力卡片：左侧低饱和线性图标徽标 + 右侧标题与正文，与边界共识卡片保持同一视觉语言。
private struct FeatureCard: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.10))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(color)
                }
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .editorialCardStyle(padding: 15)
    }
}

/// 首屏的英雄镜头：图标落位后带光晕呼吸、缓慢漂浮，并划过一道高光。
private struct HeroIcon: View {
    private let size: CGFloat = 92
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
                            Color.accentColor.opacity(0.26),
                            Color.accentColor.opacity(0)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.76
                    )
                )
                .frame(width: size * 1.85, height: size * 1.85)
                .scaleEffect(glowExpanded ? 1.1 : 0.88)
                .blur(radius: 6)

            iconImage
                .shadow(color: .black.opacity(0.2), radius: 14, x: 0, y: 8)
                .overlay(shine)
        }
        .frame(width: size * 1.4, height: size * 1.25)
        .scaleEffect((appeared || reduceMotion) ? 1 : 0.72)
        .opacity((appeared || reduceMotion) ? 1 : 0)
        .blur(radius: (appeared || reduceMotion) ? 0 : 12)
        .offset(y: ((appeared || reduceMotion) ? 0 : 16) + (floating ? -4 : 0))
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
