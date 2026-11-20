import Darwin
import Foundation

/// Account-level split layout from issue #79 and legacy member recognition for issue #110.
/// Exact account boundaries; database/configuration trees never enter the split whitelist.
struct PartialWeChatMigrationPolicy: Sendable {
    enum SplitGroup: String, CaseIterable, Sendable {
        /// 全部媒体目录（`msg` + `business`）
        case media
        /// Legacy `msg/file` + `msg/video` records for mounting and restoring.
        case filesAndVideos
    }

    struct MemberMatch: Equatable, Sendable {
        let account: URL
        let group: SplitGroup
        let relativePath: String
    }

    static let bundleIdentifier = "com.tencent.xinWeChat"
    static let memberNames = ["msg", "business"]
    static let filesAndVideosSubnames = ["file", "video"]
    static let filesAndVideosRelativePaths = ["msg/file", "msg/video"]

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

    func memberMatch(for url: URL) -> MemberMatch? {
        let normalized = url.standardizedFileURL
        let parent = normalized.deletingLastPathComponent()
        if Self.memberNames.contains(normalized.lastPathComponent), isAccount(parent) {
            return MemberMatch(account: parent, group: .media, relativePath: normalized.lastPathComponent)
        }
        let grandparent = parent.deletingLastPathComponent()
        if parent.lastPathComponent == "msg",
           Self.filesAndVideosSubnames.contains(normalized.lastPathComponent),
           isAccount(grandparent) {
            // Some WeChat builds may store a regular SQLite file named `msg/file`;
            // never classify an existing non-directory entry as a mountable split unit.
            var info = stat()
            if lstat(normalized.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR {
                return nil
            }
            return MemberMatch(account: grandparent, group: .filesAndVideos,
                               relativePath: "msg/\(normalized.lastPathComponent)")
        }
        return nil
    }

    func account(forMember url: URL) -> URL? {
        memberMatch(for: url)?.account
    }

    func splitGroup(forMember url: URL) -> SplitGroup? {
        memberMatch(for: url)?.group
    }

    func members(of account: URL, group: SplitGroup = .media) -> [URL] {
        switch group {
        case .media:
            return Self.memberNames.map { account.appendingPathComponent($0).standardizedFileURL }
        case .filesAndVideos:
            return Self.filesAndVideosRelativePaths.map { account.appendingPathComponent($0).standardizedFileURL }
        }
    }

    func existingDirectoryMembers(of account: URL, group: SplitGroup) -> [URL] {
        members(of: account, group: group).filter { url in
            var info = stat()
            return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }
    }

    static func displayMemberLabel(for url: URL) -> String {
        let normalized = url.standardizedFileURL
        if normalized.path.contains("/xwechat_files/"),
           normalized.deletingLastPathComponent().lastPathComponent == "msg",
           filesAndVideosSubnames.contains(normalized.lastPathComponent) {
            return "msg/\(normalized.lastPathComponent)"
        }
        return normalized.lastPathComponent
    }
}
