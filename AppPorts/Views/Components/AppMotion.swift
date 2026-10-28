import SwiftUI

/// Shared motion for navigation and small control feedback; list layout stays unanimated.
enum AppMotion {
    static let page = Animation.spring(response: 0.32, dampingFraction: 1)
    static let interaction = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let pageTransition = AnyTransition.opacity.combined(with: .offset(y: 6))
}

struct AppPageVisibility: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { $0.animation = nil }
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 6)
            .animation(reduceMotion ? nil : AppMotion.page, value: isVisible)
            .zIndex(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .onAppear { isVisible = isActive }
            .onChange(of: isActive) { isVisible = $0 }
    }
}

struct AppPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled && configuration.isPressed ? 0.8 : 1)
            .scaleEffect(!reduceMotion && isEnabled && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : AppMotion.interaction, value: configuration.isPressed)
    }
}
