import Foundation

/// Presentation results stay typed; localized messages never determine whether an operation succeeded.
struct AppSearchExclusionReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        case pending
        case unsupported
        case failed
        case dockWarning

        var isCompleted: Bool { self == .completed }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        /// The original path stays stable even when the app is moved or shares a name with another app.
        let id: String
        let name: String
        let iconURL: URL
        let outcome: Outcome
        let message: String

        var displayName: String {
            name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
    }

    var entries: [Entry] = []
    var operationError: String?

    var completed: [Entry] { entries.filter { $0.outcome.isCompleted } }
    var incomplete: [Entry] { entries.filter { !$0.outcome.isCompleted } }
}
