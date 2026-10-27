import Foundation

/// In-memory display snapshots. Execution still revalidates the source independently.
struct AppDataScanCache {
    struct Context: Equatable, Sendable {
        let app: AppItem
        let externalRoot: URL?
        let splitMode: Bool
        let recordsRevision: UInt64
    }

    struct Snapshot: Sendable {
        let context: Context
        var items: [DataDirItem]
        var readIssues: [DataDirReadIssue]
        let identityIssue: AppIdentityIssue?
        let isSandboxed: Bool
        let isWeChat: Bool
        let containerIdentifier: String
    }

    private var snapshots: [String: Snapshot] = [:]

    func snapshot(for context: Context, permission: LaunchReadinessChecker.FullDiskAccessState) -> Snapshot? {
        guard permission == .granted else { return nil }
        guard let snapshot = snapshots[context.app.path.path], snapshot.context == context else { return nil }
        return snapshot
    }

    mutating func store(_ snapshot: Snapshot) {
        // Do not preserve an incomplete result after a permission or identity failure.
        guard snapshot.identityIssue == nil, snapshot.readIssues.isEmpty else {
            snapshots.removeValue(forKey: snapshot.context.app.path.path)
            return
        }
        snapshots[snapshot.context.app.path.path] = snapshot
    }

    mutating func removeAll() {
        snapshots.removeAll()
    }
}
