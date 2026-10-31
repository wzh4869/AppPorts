import SwiftUI

enum AppDialogTypography {
    static let title = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
}

extension View {
    func appDialogTypography() -> some View {
        font(AppDialogTypography.body)
            .controlSize(.regular)
    }
}
