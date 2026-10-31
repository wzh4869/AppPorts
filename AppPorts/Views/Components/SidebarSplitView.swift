import AppKit
import SwiftUI

/// Own the sidebar width explicitly so its initial size does not depend on
/// HSplitView's distribution of flexible space.
struct SidebarSplitView<Sidebar: View, Content: View>: View {
    private let sidebar: Sidebar
    private let content: Content
    @State private var sidebarWidth: CGFloat = 205
    @State private var dragStartWidth: CGFloat?

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content) {
        self.sidebar = sidebar()
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Divider()
                .overlay {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { NSCursor.resizeLeftRight.set() }
                            else { NSCursor.arrow.set() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("sidebarSplit"))
                                .onChanged { value in
                                    let start = dragStartWidth ?? sidebarWidth
                                    dragStartWidth = start
                                    sidebarWidth = min(280, max(150, start + value.translation.width))
                                }
                                .onEnded { _ in dragStartWidth = nil }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("侧边栏宽度".localized)
                        .accessibilityValue(Text(verbatim: String(Int(sidebarWidth))))
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: sidebarWidth = min(280, sidebarWidth + 10)
                            case .decrement: sidebarWidth = max(150, sidebarWidth - 10)
                            @unknown default: break
                            }
                        }
                }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: "sidebarSplit")
    }
}
