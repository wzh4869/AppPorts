import Combine
import Foundation

@MainActor
final class ReadinessCheckModel: ObservableObject {
    @Published private(set) var items: [LaunchReadinessChecker.Item] = []
    @Published private(set) var isChecking = false
    private let checker: LaunchReadinessChecker
    private let didCheck: ([LaunchReadinessChecker.Item]) -> Void
    private var needsFollowUpRefresh = false

    init(checker: LaunchReadinessChecker = LaunchReadinessChecker(),
         didCheck: (([LaunchReadinessChecker.Item]) -> Void)? = nil) {
        self.checker = checker
        self.didCheck = didCheck ?? { PermissionReadiness.shared.update(from: $0) }
    }

    func refresh() {
        if isChecking {
            needsFollowUpRefresh = true
            return
        }
        isChecking = true
        needsFollowUpRefresh = false
        Task {
            while true {
                items = await checker.check()
                didCheck(items)
                guard needsFollowUpRefresh else { break }
                needsFollowUpRefresh = false
            }
            isChecking = false
        }
    }
}
