import Combine
import Foundation

@MainActor
final class ReadinessCheckModel: ObservableObject {
    @Published private(set) var items: [LaunchReadinessChecker.Item] = []
    @Published private(set) var isChecking = false
    private let checker: LaunchReadinessChecker
    private let didCheck: ([LaunchReadinessChecker.Item]) -> Void

    init(checker: LaunchReadinessChecker = LaunchReadinessChecker(),
         didCheck: (([LaunchReadinessChecker.Item]) -> Void)? = nil) {
        self.checker = checker
        self.didCheck = didCheck ?? { PermissionReadiness.shared.update(from: $0) }
    }

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            items = await checker.check()
            didCheck(items)
            isChecking = false
        }
    }
}
