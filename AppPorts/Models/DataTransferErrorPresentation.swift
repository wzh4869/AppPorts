import Foundation

extension TreeCopyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsafeLayout(let path), .mountBoundary(let path), .hardlinkOutsideSelection(let path), .relativeLinkChangesTarget(let path):
            return String(format: "数据目录包含不支持的路径关系，已停止操作并保留原件：%@".localized, path)
        case .unsupportedNode(let path), .unsupportedMetadata(let path):
            return String(format: "无法完整保留此项目的内容或权限，已停止操作并保留原件：%@".localized, path)
        case .ownershipDisabled(let path):
            return String(format: "此卷仍在忽略文件所有权，无法验证权限；已停止操作并保留原件：%@".localized, path)
        case .sourceChanged(let path), .verificationFailed(let path):
            return String(format: "数据在操作期间发生变化或校验不一致，已保留副本，请检查后重试：%@".localized, path)
        case .destinationExists(let path):
            return String(format: "目标位置已存在数据，已停止操作并保留两端：%@".localized, path)
        }
    }
}
