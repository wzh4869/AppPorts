import Combine

@MainActor
final class PermissionReadiness: ObservableObject {
    static let shared = PermissionReadiness()

    @Published private(set) var level: LaunchReadinessChecker.Item.Level?
    @Published private(set) var attentionText = ""

    func refresh() {
        update(from: [
            LaunchReadinessChecker.fullDiskAccessItem(state: LaunchReadinessChecker.fullDiskAccessState()),
            LaunchReadinessChecker.appManagementItem(state: AppManagementPermission.state())
        ])
    }

    func update(from items: [LaunchReadinessChecker.Item]) {
        let permissions = items.filter {
            $0.id == LaunchReadinessChecker.ItemID.fullDiskAccess || $0.id == LaunchReadinessChecker.ItemID.appManagement
        }
        guard !permissions.isEmpty else { return }
        level = permissions.contains { $0.level == .failed } ? .failed
            : permissions.contains { $0.level == .warning } ? .warning : .ok
        attentionText = Self.attentionText(for: permissions)
    }

    static func attentionText(for permissions: [LaunchReadinessChecker.Item]) -> String {
        permissions.filter { $0.level != .ok }.map { item in
            let status = item.level == .failed ? "需要授权".localized
                : item.id == LaunchReadinessChecker.ItemID.appManagement ? "无法确认".localized : "待核对".localized
            return item.title + " · " + status
        }.joined(separator: "；")
    }
}
