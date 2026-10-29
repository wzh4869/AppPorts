import Foundation

/// Split layout proposed by du-yuxuan in AppPorts issue #79.
/// Exact account boundaries; database/configuration trees never enter the split whitelist.
struct PartialWeChatMigrationPolicy: Sendable {
    static let bundleIdentifier = "com.tencent.xinWeChat"
    static let memberNames = ["msg", "business"]
    let homeDirectory: URL
    let containerIdentifier: String

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
         containerIdentifier: String = Self.bundleIdentifier) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.containerIdentifier = containerIdentifier
    }

    var accountsRoot: URL {
        homeDirectory.appendingPathComponent("Library/Containers/\(containerIdentifier)/Data/Documents/xwechat_files")
    }

    func isAccount(_ url: URL) -> Bool {
        guard !containerIdentifier.isEmpty, containerIdentifier != ".", containerIdentifier != "..",
              !containerIdentifier.contains("/") else { return false }
        let normalized = url.standardizedFileURL
        let path = normalized.pathComponents
        let root = accountsRoot.pathComponents
        return path.starts(with: root) && path.count == root.count + 1
            && !["all_users", "config", "resource"].contains(normalized.lastPathComponent)
    }

    func account(forMember url: URL) -> URL? {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        return Self.memberNames.contains(url.lastPathComponent) && isAccount(parent) ? parent : nil
    }

    func members(of account: URL) -> [URL] {
        Self.memberNames.map { account.appendingPathComponent($0).standardizedFileURL }
    }

    /// The offline exception applies to exact media entries, never aliases or
    /// staging directories. Existing records keep it even when split mode is off.
    func allowsOfflineReadAccess(at url: URL) -> Bool {
        guard account(forMember: url) != nil else { return false }
        let relative = url.standardizedFileURL.pathComponents.dropFirst(homeDirectory.pathComponents.count)
        let expected = relative.reduce(homeDirectory.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path == expected.standardizedFileURL.path
    }
}
