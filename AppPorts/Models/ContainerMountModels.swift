//
//  ContainerMountModels.swift
//  AppPorts
//

import Foundation

// MARK: - 挂载迁移记录

/// 沙盒应用容器数据的「挂载迁移」记录。
///
/// 沙盒应用只能访问解析后仍位于容器内的路径，符号链接指向外置盘会被内核拒绝。
/// 挂载迁移把外置盘上的一个 APFS 卷直接挂载到容器内的原目录上，路径不离开容器，
/// 应用签名与 entitlements 不做任何修改。
///
/// 记录保存在 `~/Library/Application Support/AppPorts/container-mounts.plist`，
/// 卷根目录同时写入 `.appports-mount-metadata.plist` 供反查。
struct ContainerMountRecord: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    enum OwnershipPolicy: String, Codable, Sendable {
        case owners
    }

    /// 以挂载点路径作为稳定 ID
    var id: String { mountPointPath }

    let schemaVersion: Int
    /// 关联应用显示名（仅用于展示与日志）
    let appName: String
    /// 关联应用 Bundle ID（可能读取失败）
    let bundleIdentifier: String?
    /// `DataDirType.rawValue`
    let dataDirType: String
    /// 容器内的挂载点，即原数据目录路径
    let mountPointPath: String
    /// 外置 APFS 卷的 Volume UUID，跨插拔稳定
    let volumeUUID: String
    /// 创建卷时使用的卷名（仅用于展示）
    let volumeName: String
    /// 迁移时用户选择的外部存储根目录（记录来源，不参与挂载）
    let externalRootPath: String
    let createdAt: Date
    /// Missing in historical records: explicitly use noowners for legacy application access.
    /// New verified migrations require real ownership, even after backup cleanup.
    var ownershipPolicy: OwnershipPolicy?

    init(
        appName: String,
        bundleIdentifier: String?,
        dataDirType: String,
        mountPointPath: String,
        volumeUUID: String,
        volumeName: String,
        externalRootPath: String,
        createdAt: Date = Date(),
        ownershipPolicy: OwnershipPolicy? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.dataDirType = dataDirType
        self.mountPointPath = mountPointPath
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.externalRootPath = externalRootPath
        self.createdAt = createdAt
        self.ownershipPolicy = ownershipPolicy
    }

    var mountPointURL: URL {
        URL(fileURLWithPath: mountPointPath)
    }
}

/// 操作完成后仍需清理的副本。与活动挂载记录分开保存，不能被自动重挂。
struct ContainerCleanupRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case migrationBackup
        case restoredVolume
    }

    let id: UUID
    let kind: Kind
    let mountRecord: ContainerMountRecord
    /// migrationBackup 为保留的备份；restoredVolume 为已经还原的本地目录。
    let localPath: String
    /// 还原开始切换前就保存；切换中断时据此找到已复制的本地副本。
    let restoreStagingPath: String?

    init(kind: Kind, mountRecord: ContainerMountRecord, localPath: String, restoreStagingPath: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.mountRecord = mountRecord
        self.localPath = localPath
        self.restoreStagingPath = restoreStagingPath
    }
}
