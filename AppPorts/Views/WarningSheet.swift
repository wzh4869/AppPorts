//
//  WarningSheet.swift
//  AppPorts
//
//  全应用统一的警示弹窗样式：图标 + 标题、要点列表、勾选确认、右下角按钮组。
//
//  取代此前散落的系统 `.alert`。相比 alert：
//  - 内容长时正文内部滚动，标题和按钮永远可见；
//  - Esc 一律等于取消；
//  - 不可逆操作可以要求先勾选「我已了解以上风险」才解锁。
//

import SwiftUI

/// 警示弹窗里的一个要点
struct WarningBullet: Identifiable {
    let id = UUID()
    let icon: String
    let text: String

    init(_ icon: String, _ text: String) {
        self.icon = icon
        self.text = text
    }
}

/// 警示弹窗底部的一个操作
struct WarningAction {
    /// 按钮外观
    enum Style {
        /// 次要操作：描边按钮
        case normal
        /// 推荐操作：蓝色高亮
        case preferred
        /// 危险/不可逆操作：红色高亮
        case destructive
    }

    let title: String
    var style: Style = .normal
    /// 是否要先勾选「我已了解」才可点
    var requiresAcknowledgement = false
    let handler: () -> Void

    init(
        _ title: String,
        style: Style = .normal,
        requiresAcknowledgement: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.requiresAcknowledgement = requiresAcknowledgement
        self.handler = handler
    }
}

/// 统一的警示弹窗
struct WarningSheet: View {
    let title: String
    var icon: String = "exclamationmark.triangle.fill"
    var tint: Color = .red
    /// 标题下的引言
    var intro: String?
    /// 要点列表
    var bullets: [WarningBullet] = []
    /// 灰字补充说明
    var detail: String?
    /// 勾选项文案；为 nil 时整个勾选行不出现
    var acknowledgementTitle: String?
    /// 进一步说明的文档页，渲染成可点击的「详情请参阅」。
    var documentationURL: URL?
    /// 次要操作（取消）
    var cancelTitle: String = "取消".localized
    var onCancel: () -> Void
    /// 主操作，按数组顺序从左到右排
    var actions: [WarningAction] = []
    /// 弹窗被「处理掉」时（任意按钮或 Esc）先调用，再执行按钮自己的动作。
    ///
    /// `.sheet(item:)` 不会因为点了内部按钮就自动关闭 —— item 必须显式置回 nil。
    /// 漏掉这一步的症状是「按钮点了没反应」：弹窗不关，再点又会撞上
    /// `AppOperationState` 的忙碌判断被静默忽略，整个弹窗看上去是死的。
    /// 统一在这里回调，使用方就没有机会忘（改用这个之前，11 个弹窗有 10 个漏了这一步）。
    var onResolve: () -> Void = {}

    @State private var acknowledged = false

    private let contentMaxHeight: CGFloat = 420
    private let sheetWidth: CGFloat = 520
    private let contentPadding: CGFloat = 24

    private var needsAcknowledgement: Bool {
        actions.contains { $0.requiresAcknowledgement }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if let intro {
                        Text(intro)
                            .font(AppDialogTypography.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }

                    if !bullets.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(bullets) { bullet in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: bullet.icon)
                                        .frame(width: 16)
                                    Text(bullet.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(AppDialogTypography.body)
                                .foregroundColor(.secondary)
                            }
                        }
                    }

                    if let detail {
                        Text(detail)
                            .font(AppDialogTypography.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let documentationURL {
                        Link(destination: documentationURL) {
                            HStack(spacing: 4) {
                                Text("详情请参阅文档".localized)
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(AppDialogTypography.body)
                        }
                        .help(documentationURL.absoluteString)
                    }
                }
                .frame(width: sheetWidth - contentPadding * 2, alignment: .leading)
                .padding(.vertical, 16)
            }
            .frame(maxHeight: contentMaxHeight)

            if let acknowledgementTitle, needsAcknowledgement {
                acknowledgementRow(acknowledgementTitle)
            }

            Divider()
            actionBar
        }
        .padding(contentPadding)
        .appDialogTypography()
        .frame(width: sheetWidth)
    }

    // MARK: - 局部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(tint)

            Text(title)
                .font(AppDialogTypography.title)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
    }

    private func acknowledgementRow(_ text: String) -> some View {
        Toggle(text, isOn: $acknowledged)
            .toggleStyle(.checkbox)
            .padding(.bottom, 12)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            Button(cancelTitle) { resolve(onCancel) }
                .keyboardShortcut(.cancelAction)

            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                button(for: action)
            }
        }
        .padding(.top, 14)
    }

    /// 先让使用方把「正在展示的弹窗」置空，再执行按钮自己的动作。
    ///
    /// 顺序不能反：有的动作会在处理过程中立刻发起下一个弹窗，
    /// 必须是「先关旧的、再开新的」，否则新的会被这一次关闭一起吞掉。
    private func resolve(_ body: () -> Void) {
        onResolve()
        body()
    }

    @ViewBuilder
    private func button(for action: WarningAction) -> some View {
        let disabled = action.requiresAcknowledgement && !acknowledged

        switch action.style {
        case .destructive:
            Button(action.title) { resolve(action.handler) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(disabled)
        case .preferred:
            Button(action.title) { resolve(action.handler) }
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
        case .normal:
            Button(action.title) { resolve(action.handler) }
                .buttonStyle(.bordered)
                .disabled(disabled)
        }
    }
}

/// 一次弹窗展示所需的全部内容。
///
/// 用 `.sheet(item:)` 而不是 `.sheet(isPresented:)`：后者会在发起展示的同一次更新里
/// 用**旧值**构建内容，弹窗会先渲染成一个「只有图标、没有标题和正文」的空壳，
/// 而且不一定自我修正（实测三次里出现两次）。把内容本身当作展示开关，
/// 弹窗就一定按写入时的那份内容构建。
struct WarningSheetRequest: Identifiable {
    let id = UUID()
    var title: String
    var icon: String = "exclamationmark.triangle.fill"
    var tint: Color = .red
    var intro: String?
    var bullets: [WarningBullet] = []
    var detail: String?
    var acknowledgementTitle: String?
    /// 进一步说明的文档页；非 nil 时在正文底部显示「详情请参阅」链接。
    var documentationURL: URL?
    var cancelTitle: String = "取消".localized
    var onCancel: () -> Void = {}
    var actions: [WarningAction] = []
}

extension View {
    /// 用 `.sheet(item:)` 展示一个警示弹窗，并把「关闭」这件事一并接好。
    ///
    /// 用这个而不是手写 `.sheet(item: $x) { WarningSheet($0) }`：
    /// 手写的版本没有绑定 `onResolve`，弹窗永远关不掉。收敛到这里，使用方就没有机会忘。
    func warningSheet(_ request: Binding<WarningSheetRequest?>) -> some View {
        sheet(item: request) { value in
            WarningSheet(value, onResolve: { request.wrappedValue = nil })
        }
    }
}

extension WarningSheet {
    init(_ request: WarningSheetRequest, onResolve: @escaping () -> Void = {}) {
        self.init(
            title: request.title,
            icon: request.icon,
            tint: request.tint,
            intro: request.intro,
            bullets: request.bullets,
            detail: request.detail,
            acknowledgementTitle: request.acknowledgementTitle,
            documentationURL: request.documentationURL,
            cancelTitle: request.cancelTitle,
            onCancel: request.onCancel,
            actions: request.actions,
            onResolve: onResolve
        )
    }
}
