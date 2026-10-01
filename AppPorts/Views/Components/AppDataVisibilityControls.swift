import SwiftUI

/// App-data visibility only; execution policy and tool-directory controls remain independent.
struct AppDataVisibilityControls: View {
    @Binding var showZeroByteDirectories: Bool
    @Binding var showLockedStructure: Bool

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 640 {
                VStack(alignment: .leading, spacing: 6) {
                    zeroByteDirectoriesToggle
                    lockedStructureToggle
                }
            } else {
                HStack(spacing: 12) {
                    zeroByteDirectoriesToggle
                    lockedStructureToggle
                }
            }
        }
        .frame(height: 42)
    }

    private var zeroByteDirectoriesToggle: some View {
        Toggle("显示零字节目录".localized, isOn: $showZeroByteDirectories)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .fixedSize()
    }

    private var lockedStructureToggle: some View {
        Toggle("显示锁定目录结构".localized, isOn: $showLockedStructure)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .fixedSize()
    }
}
