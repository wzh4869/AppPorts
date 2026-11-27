import SwiftUI

/// Shared motion for navigation and small control feedback; list layout stays unanimated.
enum AppMotion {
    static let interaction = Animation.spring(response: 0.28, dampingFraction: 0.82)
}

private struct IsPageActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isPageActive: Bool {
        get { self[IsPageActiveKey.self] }
        set { self[IsPageActiveKey.self] = newValue }
    }
}

struct AppPageVisibility: ViewModifier {
    let isActive: Bool
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { $0.animation = nil }
            .opacity(isActive ? 1 : 0)
            .zIndex(isActive ? 1 : -1)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .environment(\.isPageActive, isActive)
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
