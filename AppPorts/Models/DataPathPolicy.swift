import Foundation

/// A path's migration permission is independent from the ability to recover an older migration.
/// Rules use the actual user's container roots and exact components, never a substring named Containers.
struct DataPathPolicy: Sendable {
    enum Role: String, Equatable, Sendable {
        case ordinaryContainerRoot, containerDataRoot, systemDirectory, groupContainerRoot
        case weChatCompatibilityDirectory, businessData, unrelated
    }

    enum Reason: String, Equatable, Sendable {
        case systemManagedStructure, weChatCompatibility, runtimeConflict, readFailure, retainedOriginal

        var localizedDescription: String {
            switch self {
            case .systemManagedStructure:
                return "此目录由 macOS 管理，只能迁移其允许的子目录。".localized
            case .weChatCompatibility:
                return "为保持微信兼容性，此目录不能新迁移；已有迁移仍可还原。".localized
            case .runtimeConflict:
                return "此路径存在链接或挂载冲突，请先检查现有数据。".localized
            case .readFailure:
                return "目录无法完整读取，请检查访问权限后重试。".localized
            case .retainedOriginal:
                return "原件仍保留，清理后才会释放空间。".localized
            }
        }
    }

    struct Decision: Equatable, Sendable {
        let role: Role
        let reason: Reason?
        let canMigrate: Bool
        /// Structural discovery only. Callers must additionally reject mount points and read failures.
        let mayDiscoverChildren: Bool
    }

    let homeDirectory: URL

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    func evaluate(_ url: URL) -> Decision {
        let lexical = classify(url.standardizedFileURL, home: homeDirectory)
        let resolved = classify(url.resolvingSymlinksInPath(), home: homeDirectory.resolvingSymlinksInPath())
        // Preserve the protected source role even when a historical link points out of the container.
        let result = !lexical.canMigrate ? lexical : (!resolved.canMigrate ? resolved : lexical.role == .unrelated ? resolved : lexical)
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        return Decision(role: result.role, reason: result.reason, canMigrate: result.canMigrate,
                        mayDiscoverChildren: result.mayDiscoverChildren && !isLink)
    }

    private func classify(_ url: URL, home: URL) -> Decision {
        let path = url.standardizedFileURL.pathComponents
        let ordinary = home.appendingPathComponent("Library/Containers").standardizedFileURL.pathComponents
        let group = home.appendingPathComponent("Library/Group Containers").standardizedFileURL.pathComponents
        if path.starts(with: group), path.count > group.count {
            return path.count == group.count + 1
                ? locked(.groupContainerRoot, .systemManagedStructure)
                : allowed(.businessData)
        }
        guard path.starts(with: ordinary), path.count > ordinary.count else { return allowed(.unrelated) }
        let relative = Array(path.dropFirst(ordinary.count))
        if relative.count == 1 { return locked(.ordinaryContainerRoot, .systemManagedStructure) }
        guard relative[1] == "Data" else { return locked(.systemDirectory, .systemManagedStructure, discover: false) }
        if relative.count == 2 { return locked(.containerDataRoot, .systemManagedStructure) }
        let dataRelative = Array(relative.dropFirst(2))
        let exactLocks: Set<String> = ["Documents", "Library", "Library/Application Scripts", "Library/Application Support",
                                      "Library/Caches", "Library/Images", "Library/Logs", "Library/Preferences",
                                      "Library/Saved Application State", "SystemData", "tmp"]
        if exactLocks.contains(dataRelative.joined(separator: "/")) { return locked(.systemDirectory, .systemManagedStructure) }
        if relative[0] == "com.tencent.xinWeChat" {
            let directAccount = dataRelative.count == 3 && dataRelative.starts(with: ["Documents", "xwechat_files"])
            let support = dataRelative == ["Library", "Application Support", "com.tencent.xinWeChat"]
            if directAccount || support { return allowed(.businessData) }
            return locked(.weChatCompatibilityDirectory, .weChatCompatibility,
                          discover: dataRelative.count < 3)
        }
        return allowed(.businessData)
    }

    private func locked(_ role: Role, _ reason: Reason, discover: Bool = true) -> Decision {
        Decision(role: role, reason: reason, canMigrate: false, mayDiscoverChildren: discover)
    }

    private func allowed(_ role: Role) -> Decision {
        Decision(role: role, reason: nil, canMigrate: true, mayDiscoverChildren: false)
    }
}
