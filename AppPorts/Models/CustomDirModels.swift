//
//  CustomDirModels.swift
//  AppPorts
//
//  Created by Codex on 2026/6/26.
//

import Foundation

enum CustomDirStatus {
    static let local = "本地"
    static let linked = "已链接"
    static let orphanedLink = "孤立链接"
    static let pendingRelink = "待接回"
    static let missing = "未找到"
    static let external = "外部"
    static let destinationConflict = "目标冲突"
}

struct CustomDirConfig: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var localPath: String
    var externalBasePath: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        localPath: String,
        externalBasePath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.localPath = localPath
        self.externalBasePath = externalBasePath
        self.createdAt = createdAt
    }

    nonisolated var localURL: URL {
        URL(fileURLWithPath: localPath).standardizedFileURL
    }

    nonisolated var externalBaseURL: URL {
        URL(fileURLWithPath: externalBasePath).standardizedFileURL
    }

    nonisolated var externalDestinationURL: URL {
        externalBaseURL.appendingPathComponent(localURL.lastPathComponent).standardizedFileURL
    }

    nonisolated var displayName: String {
        localURL.lastPathComponent
    }
}

enum CustomDirValidationError: LocalizedError, Equatable {
    case localNotDirectory
    case externalNotDirectory
    case localOutsideHome
    case localIsHome
    case localIsSymlink
    case localOverlapsManagedDirectory
    case externalInsideLocal
    case localInsideExternal
    case externalInsideHome
    case externalOverlapsManagedDirectory

    var errorDescription: String? {
        switch self {
        case .localNotDirectory:
            return "本地目录不存在或不是文件夹".localized
        case .externalNotDirectory:
            return "外部目标不是文件夹".localized
        case .externalInsideLocal:
            return "外部目标不能位于本地目录内部".localized
        case .localInsideExternal:
            return "本地目录不能位于外部目标内部".localized
        case .localOutsideHome:
            return "本地目录必须位于当前用户目录下".localized
        case .localIsHome:
            return "不能迁移整个用户目录".localized
        case .localIsSymlink:
            return "不能迁移软链接目录，请选择真实文件夹".localized
        case .localOverlapsManagedDirectory:
            return "该目录与已管理目录存在包含关系".localized
        case .externalInsideHome:
            return "外部目标不能位于当前用户目录内".localized
        case .externalOverlapsManagedDirectory:
            return "外部目标与已管理目录存在包含关系".localized
        }
    }
}

enum CustomDirValidator {
    static func validateLocalDirectory(
        _ localURL: URL,
        existingConfigs: [CustomDirConfig],
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let homeURL = homeURL.standardizedFileURL
        let localPath = normalizedPath(localURL)
        let homePath = normalizedPath(homeURL)

        if containsSymbolicLinkInLocalPath(localURL, homeURL: homeURL, fileManager: fileManager) {
            throw CustomDirValidationError.localIsSymlink
        }

        var isLocalDir: ObjCBool = false
        guard fileManager.fileExists(atPath: localPath, isDirectory: &isLocalDir), isLocalDir.boolValue else {
            throw CustomDirValidationError.localNotDirectory
        }

        if localPath == homePath {
            throw CustomDirValidationError.localIsHome
        }

        guard isDescendant(localPath, of: homePath) else {
            throw CustomDirValidationError.localOutsideHome
        }

        for config in existingConfigs {
            if pathsOverlap(localPath, normalizedPath(config.localURL))
                || pathsOverlap(localPath, normalizedPath(config.externalDestinationURL)) {
                throw CustomDirValidationError.localOverlapsManagedDirectory
            }
        }
    }

    static func validate(
        localURL: URL,
        externalBaseURL: URL,
        existingConfigs: [CustomDirConfig],
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        try validateLocalDirectory(
            localURL,
            existingConfigs: existingConfigs,
            homeURL: homeURL,
            fileManager: fileManager
        )
        try validateExternalBaseDirectory(
            externalBaseURL,
            homeURL: homeURL,
            fileManager: fileManager
        )

        let localPath = normalizedPath(localURL)
        let externalBasePath = normalizedPath(externalBaseURL)
        let finalPath = normalizedPath(
            externalBaseURL.appendingPathComponent(localURL.lastPathComponent)
        )

        if isDescendant(finalPath, of: localPath) {
            throw CustomDirValidationError.externalInsideLocal
        }

        if isDescendant(localPath, of: finalPath) || localPath == externalBasePath {
            throw CustomDirValidationError.localInsideExternal
        }

        for config in existingConfigs {
            if pathsOverlap(finalPath, normalizedPath(config.localURL))
                || pathsOverlap(finalPath, normalizedPath(config.externalDestinationURL)) {
                throw CustomDirValidationError.externalOverlapsManagedDirectory
            }
        }
    }

    static func validateExternalBaseDirectory(
        _ externalBaseURL: URL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let externalBasePath = normalizedPath(externalBaseURL)
        let homePath = normalizedPath(homeURL)

        var isExternalDir: ObjCBool = false
        guard fileManager.fileExists(atPath: externalBasePath, isDirectory: &isExternalDir),
              isExternalDir.boolValue else {
            throw CustomDirValidationError.externalNotDirectory
        }

        if isSameOrDescendant(externalBasePath, of: homePath) {
            throw CustomDirValidationError.externalInsideHome
        }
    }

    private static func isSymbolicLink(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attributes[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeSymbolicLink
    }

    static func containsSymbolicLinkInLocalPath(
        _ localURL: URL,
        homeURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let localPath = normalizedPath(localURL)
        let homePath = normalizedPath(homeURL)

        guard isSameOrDescendant(localPath, of: homePath) else {
            return isSymbolicLink(at: localURL, fileManager: fileManager)
        }

        var currentPath = localPath
        while isSameOrDescendant(currentPath, of: homePath) {
            if isSymbolicLink(at: URL(fileURLWithPath: currentPath), fileManager: fileManager) {
                return true
            }

            if currentPath == homePath {
                break
            }

            let parentPath = stripTrailingSlash(URL(fileURLWithPath: currentPath).deletingLastPathComponent().path)
            guard parentPath != currentPath else {
                break
            }
            currentPath = parentPath
        }

        return false
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        isSameOrDescendant(lhs, of: rhs) || isSameOrDescendant(rhs, of: lhs)
    }

    private static func isDescendant(_ candidate: String, of root: String) -> Bool {
        candidate != root && isSameOrDescendant(candidate, of: root)
    }

    private static func isSameOrDescendant(_ candidate: String, of root: String) -> Bool {
        let candidate = stripTrailingSlash(candidate)
        let root = stripTrailingSlash(root)
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        stripTrailingSlash(url.standardizedFileURL.path)
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

struct CustomDirLocalOpenPanelGuard {
    private let homeURL: URL
    private let existingConfigs: [CustomDirConfig]
    private let fileManager: FileManager

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        existingConfigs: [CustomDirConfig],
        fileManager: FileManager = .default
    ) {
        self.homeURL = homeURL
        self.existingConfigs = existingConfigs
        self.fileManager = fileManager
    }

    func shouldEnable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        return !CustomDirValidator.containsSymbolicLinkInLocalPath(
            url,
            homeURL: homeURL,
            fileManager: fileManager
        )
    }

    func validationError(for url: URL) -> Error? {
        do {
            try CustomDirValidator.validateLocalDirectory(
                url,
                existingConfigs: existingConfigs,
                homeURL: homeURL,
                fileManager: fileManager
            )
            return nil
        } catch {
            return error
        }
    }
}

enum CustomDirEntryKind: String, Sendable {
    case local
    case external
}

struct CustomDirEntry: Identifiable, Equatable, Sendable {
    var config: CustomDirConfig
    var kind: CustomDirEntryKind
    var url: URL
    var status: String
    var size: String? = nil
    var sizeBytes: Int64 = 0
    var linkedDestination: URL? = nil

    nonisolated var id: String {
        "\(config.id.uuidString)-\(kind.rawValue)"
    }

    nonisolated var name: String {
        config.displayName
    }

    nonisolated var counterpartURL: URL {
        switch kind {
        case .local:
            return config.externalDestinationURL
        case .external:
            return config.localURL
        }
    }

    nonisolated var dataDirItem: DataDirItem {
        DataDirItem(
            name: name,
            path: url,
            type: .custom,
            priority: .recommended,
            description: "目录迁移".localized,
            status: status,
            size: size,
            sizeBytes: sizeBytes,
            isMigratable: status == CustomDirStatus.local,
            linkedDestination: linkedDestination
        )
    }
}

struct CustomDirPair: Identifiable, Equatable, Sendable {
    var config: CustomDirConfig
    var local: CustomDirEntry
    var external: CustomDirEntry

    nonisolated var id: UUID {
        config.id
    }

    nonisolated static func pendingMigration(for config: CustomDirConfig) -> CustomDirPair {
        CustomDirPair(
            config: config,
            local: CustomDirEntry(
                config: config,
                kind: .local,
                url: config.localURL,
                status: CustomDirStatus.local
            ),
            external: CustomDirEntry(
                config: config,
                kind: .external,
                url: config.externalDestinationURL,
                status: CustomDirStatus.missing
            )
        )
    }
}
