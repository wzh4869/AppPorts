//
//  MountMigrationPreflight.swift
//  AppPorts
//

import Foundation

// MARK: - 挂载迁移前的只读检查

/// 用户点「挂载迁移」时，先看一眼目标外部存储，再决定给确认框还是给引导。
///
/// 大多数用户不知道自己的盘是什么格式，也不想为了迁移去动盘。与其等用户确认后才报
/// 「不是 APFS」，不如先查清楚：能迁移就说明会发生什么；不能迁移就说明「保留现状也没关系」
/// 和其他可选的路。检查只读，不创建卷、不改动任何文件。
///
/// 迁移器执行时仍会再查一遍，这里只负责提前告诉用户。
struct MountMigrationPreflight: Sendable {

    enum Outcome: Equatable, Sendable {
        /// 可以迁移；`availableBytes` 查不到时为 nil
        case ready(availableBytes: Int64?)
        /// 还没选外部存储
        case noDestination
        /// 选了但读不到（没连接、已推出）
        case destinationUnavailable
        /// 不是 APFS（exFAT、NTFS、HFS+ 等）；`filesystem` 是 diskutil 给出的原始类型
        case notAPFS(filesystem: String?)
        /// 可以迁移到加密 APFS；开始前需为新数据卷设置密码
        case encrypted
        /// 空间不够
        case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    }

    /// 检测用到的外部依赖；测试注入假实现，不碰真实磁盘。
    struct Probe: Sendable {
        var pathExists: @Sendable (URL) -> Bool
        var volumeInfo: @Sendable (URL) async -> DiskUtility.VolumeInfo?
        var availableCapacity: @Sendable (URL) -> Int64?
    }

    let probe: Probe

    init(probe: Probe = .live) {
        self.probe = probe
    }

    /// - Parameters:
    ///   - destination: 用户选择的外部存储路径
    ///   - dataBytes: 要迁移的数据大小；未知时传 0，此时不检查空间
    func evaluate(destination: URL?, dataBytes: Int64) async -> Outcome {
        guard let destination else { return .noDestination }
        guard probe.pathExists(destination), let info = await probe.volumeInfo(destination) else {
            return .destinationUnavailable
        }
        guard info.isAPFS, info.apfsContainerReference != nil else {
            return .notAPFS(filesystem: info.filesystemType)
        }
        let available = probe.availableCapacity(destination)
        if dataBytes > 0, let available {
            let required = ContainerVolumeMigrator.requiredFreeBytes(forDataBytes: dataBytes)
            if available < required {
                return .insufficientSpace(requiredBytes: required, availableBytes: available)
            }
        }
        return info.isEncrypted ? .encrypted : .ready(availableBytes: available)
    }
}

extension MountMigrationPreflight.Probe {
    /// 真机实现。只做查询，不需要管理员权限，也不会弹授权框。
    static let live = MountMigrationPreflight.Probe(
        pathExists: { FileManager.default.fileExists(atPath: $0.path) },
        volumeInfo: { url in
            // diskutil 只认卷的挂载点或设备，不认卷内子目录。
            let volumePath = DiskUtility.mountedVolumePath(containing: url) ?? url.path
            return try? await DiskUtility(commandTimeout: 30, administratorRunner: nil).volumeInfo(for: volumePath)
        },
        availableCapacity: { DiskUtility.availableCapacity(at: $0) }
    )
}

// MARK: - 引导内容

/// 把检查结果变成用户看得懂的下一步。
///
/// 只描述内容和可选操作，按钮动作由界面绑定。原则：
/// - 能迁移时说清会发生什么、不会发生什么（不抹盘、不重签名）；
/// - 不能迁移时先告诉用户「保留现状也没关系」，其他做法只作为选项，不高亮催促；
/// - 路径、卷、APFS 等技术细节放在灰字补充里。
struct MountMigrationGuidance: Equatable {
    struct Action: Equatable {
        enum Kind: Equatable {
            /// 开始迁移
            case migrate
            /// 选择（其他）外部存储
            case chooseDestination
            /// 打开文档里对应的说明（页面路径与页内锚点，见 `DocumentationLink`）
            case openGuide(page: String, anchor: String?)
            /// 重新检查
            case recheck
        }

        let kind: Kind
        let title: String
        /// 是否作为推荐操作高亮
        let isPrimary: Bool
    }

    struct Bullet: Equatable {
        let icon: String
        let text: String
    }

    let title: String
    let icon: String
    /// 能否直接迁移；决定弹窗的配色
    let isReady: Bool
    let intro: String
    let bullets: [Bullet]
    let detail: String?
    let actions: [Action]
    /// 取消按钮文案。不能迁移时是「保留现状」，强调什么都不做也可以。
    let cancelTitle: String

    /// 用户认得的是盘名（`/Volumes/hano/AppPorts` 里的 hano），不是其中的文件夹名。
    static func driveName(for path: String) -> String {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if components.count > 2, components[1] == "Volumes" { return components[2] }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// - Parameters:
    ///   - appName: 关联应用显示名
    ///   - dataSize: 数据大小的显示文本；未知时为 nil
    ///   - sourcePath: 数据目录（已把家目录缩写为 ~）
    ///   - destinationPath: 外部存储路径
    static func make(
        outcome: MountMigrationPreflight.Outcome,
        appName: String,
        dataSize: String?,
        sourcePath: String,
        destinationPath: String?
    ) -> MountMigrationGuidance {
        let destinationName = destinationPath.map(driveName(for:)) ?? ""
        let paths = String(format: "数据目录：%@\n外部存储：%@".localized, sourcePath, destinationPath ?? "—")
        let keepAsIs = Bullet(
            icon: "checkmark.circle",
            text: String(format: "保留现状：「%@」的数据继续留在本机，一切照旧，以后随时可以再迁移".localized, appName)
        )

        switch outcome {
        case .ready:
            var bullets = [
                Bullet(icon: "checkmark.shield", text: "不会抹掉或重新分区外部存储，盘上现有文件保持不变".localized),
                Bullet(icon: "eye.slash", text: "新建的数据卷与盘上其他内容共享剩余空间，平时不会出现在 Finder 边栏和桌面".localized),
                Bullet(icon: "hand.raised", text: String(format: "迁移后第一次打开「%@」时，系统会询问是否允许访问可移动宗卷，请点「允许」".localized, appName)),
                Bullet(icon: "cable.connector", text: String(format: "使用「%@」前先连接这块外部存储。未连接时应用可能无法访问数据，连接后 AppPorts 会尝试重新挂载。".localized, appName)),
                Bullet(icon: "lock.open", text: "这块外部存储没有加密：盘丢失时，别人可以读取迁移过去的数据".localized)
            ]
            if let dataSize {
                bullets.insert(Bullet(icon: "internaldrive", text: String(format: "本机将释放约 %@ 空间".localized, dataSize)), at: 0)
            }
            return MountMigrationGuidance(
                title: String(format: "迁移「%@」的数据".localized, appName),
                icon: "externaldrive.fill.badge.plus",
                isReady: true,
                intro: String(
                    format: "将「%@」的数据迁移到外部存储「%@」，保留原始签名。应用继续使用原来的数据位置。".localized,
                    appName,
                    destinationName
                ),
                bullets: bullets,
                detail: paths + "\n" + "挂载迁移".localized + " · APFS",
                actions: [Action(kind: .migrate, title: "迁移数据".localized, isPrimary: true)],
                cancelTitle: "取消".localized
            )

        case .noDestination:
            return MountMigrationGuidance(
                title: "先选择外部存储".localized,
                icon: "externaldrive",
                isReady: false,
                intro: String(format: "挂载迁移会把「%@」的数据放到你选择的外部存储上。选好位置之前，不会改动任何东西。".localized, appName),
                bullets: [],
                detail: nil,
                actions: [Action(kind: .chooseDestination, title: "选择外部存储".localized, isPrimary: true)],
                cancelTitle: "取消".localized
            )

        case .destinationUnavailable:
            return MountMigrationGuidance(
                title: "外部存储未连接".localized,
                icon: "externaldrive.badge.xmark",
                isReady: false,
                intro: String(format: "读不到当前选择的外部存储「%@」，它可能没有连接或已被推出。连接后点「重新检查」；没有做任何改动。".localized, destinationName),
                bullets: [],
                detail: paths,
                actions: [
                    Action(kind: .recheck, title: "重新检查".localized, isPrimary: true),
                    Action(kind: .chooseDestination, title: "选择其他位置".localized, isPrimary: false)
                ],
                cancelTitle: "取消".localized
            )

        case .notAPFS(let filesystem):
            let format = LaunchReadinessChecker.filesystemDisplayName(filesystem) ?? "未知格式".localized
            let convert: String
            if filesystem?.lowercased().hasPrefix("hfs") == true {
                convert = "想把这块盘改成 APFS：Mac OS 扩展（HFS+）可以用「磁盘工具」无损转换为 APFS，转换前请先备份".localized
            } else {
                convert = String(format: "想把这块盘改成 APFS：macOS 不能无损转换 %@，需要先备份再抹掉，或在未分配的空间上新建 APFS 分区，步骤见准备方法".localized, format)
            }
            return MountMigrationGuidance(
                title: String(format: "这块外部存储是 %@ 格式".localized, format),
                icon: "info.circle",
                isReady: false,
                intro: "沙盒应用的数据只能迁移到 APFS 格式的外部存储。你不需要为此改动这块盘：应用本体和其他数据目录照常可以迁移到这里。".localized,
                bullets: [
                    keepAsIs,
                    Bullet(icon: "externaldrive", text: "改用另一块 APFS 格式的外部存储，或这块盘上已有的 APFS 分区".localized),
                    Bullet(icon: "arrow.triangle.2.circlepath", text: convert)
                ],
                detail: paths,
                actions: [
                    Action(kind: .chooseDestination, title: "选择其他位置".localized, isPrimary: false),
                    Action(kind: .openGuide(page: "storage-guide", anchor: "prepare-apfs"), title: "查看准备方法".localized, isPrimary: false)
                ],
                cancelTitle: "保留现状".localized
            )

        case .encrypted:
            return MountMigrationGuidance(
                title: String(format: "迁移「%@」的数据".localized, appName),
                icon: "lock.shield",
                isReady: true,
                intro: "将创建独立加密的数据卷，继续后设置密码。外置盘现有密码和文件保持不变。".localized,
                bullets: [
                    Bullet(icon: "key", text: "可以选择保存到本机钥匙串，以便登录或连接外置盘后自动解锁。".localized),
                    Bullet(icon: "lock", text: "未保存密码时，需要手动解锁；后台不会反复弹出密码框。".localized)
                ],
                detail: paths,
                actions: [Action(kind: .migrate, title: "继续".localized, isPrimary: true)],
                cancelTitle: "取消".localized
            )

        case .insufficientSpace(let required, let available):
            return MountMigrationGuidance(
                title: "外部存储空间不足".localized,
                icon: "externaldrive.badge.minus",
                isReady: false,
                intro: String(
                    format: "迁移「%@」的数据需要约 %@ 可用空间，外部存储「%@」目前只有 %@。清理出空间或改选其他位置后再试；没有做任何改动。".localized,
                    appName,
                    LocalizedByteCountFormatter.string(fromByteCount: required),
                    destinationName,
                    LocalizedByteCountFormatter.string(fromByteCount: available)
                ),
                bullets: [],
                detail: paths,
                actions: [
                    Action(kind: .recheck, title: "重新检查".localized, isPrimary: false),
                    Action(kind: .chooseDestination, title: "选择其他位置".localized, isPrimary: false)
                ],
                cancelTitle: "取消".localized
            )
        }
    }
}
