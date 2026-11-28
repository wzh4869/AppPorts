import AppKit
import SwiftUI

enum AppSurfaceColors {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 26 / 255, green: 27 / 255, blue: 29 / 255, alpha: 1)
            : NSColor(srgbRed: 246 / 255, green: 246 / 255, blue: 248 / 255, alpha: 1)
    })

    static let content = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 35 / 255, green: 37 / 255, blue: 39 / 255, alpha: 1)
            : .white
    })

    static let opaqueSidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1)
            : NSColor(white: 0.95, alpha: 1)
    })

    static func sidebarTint(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 0.03, green: 0.075, blue: 0.09, opacity: 0.60)
            : .white.opacity(0.25)
    }
}
