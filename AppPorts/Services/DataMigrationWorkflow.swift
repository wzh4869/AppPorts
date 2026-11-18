import Foundation

/// Migration changes the data location only. Signing is a separate user action.
enum DataMigrationWorkflow {
    struct SigningTarget: Equatable, Sendable {
        let url: URL
        let isSandboxed: Bool
        let identity: DataPathIdentity?
        let fingerprint: String?
        let temporarySpaceRequirement: SignatureTemporarySpaceRequirement

        init(url: URL, isSandboxed: Bool, identity: DataPathIdentity? = nil, fingerprint: String? = nil,
             temporarySpaceRequirement: SignatureTemporarySpaceRequirement) {
            self.url = url.standardizedFileURL
            self.isSandboxed = isSandboxed
            self.identity = identity
            self.fingerprint = fingerprint
            self.temporarySpaceRequirement = temporarySpaceRequirement
        }

        var confirmationMessage: String {
            var message = String(format: "将重签「%@」。AppPorts 会自动保留仍有恢复价值的官方原包，并在确认恢复官方状态后清理。你可以在应用上使用“恢复原始签名”。".localized,
                url.lastPathComponent)
            message += "\n" + "原包将自动保存到外盘的 AppPorts Backups 文件夹。".localized
            message += "\n\n" + String(format: "临时位置：%@\n预计额外空间：%@（按完整复制预留）。".localized,
                temporarySpaceRequirement.parentURL.path,
                LocalizedByteCountFormatter.string(fromByteCount: temporarySpaceRequirement.requiredAdditionalBytes))
            return message + "\n\n" + (isSandboxed
                ? "这会更换开发者签名，并可能改变沙盒、应用组和钥匙串访问；签名通过不代表应用能够启动或访问原数据。".localized
                : "签名通过不代表应用能够启动，钥匙串或其他系统授权也可能改变。".localized)
        }
    }

    private struct InspectionFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// A confirmation belongs to this bundle, not just a reusable path.
    static func signingTarget(at appURL: URL) throws -> SigningTarget {
        let realURL = try CodeSigner.resolveAppURL(at: appURL)
        let sandboxed: Bool
        switch CodeSigner.sandboxStatus(at: realURL) {
        case .sandboxed: sandboxed = true
        case .notSandboxed, .unsigned: sandboxed = false
        case .unavailable(let reason): throw InspectionFailure(reason: reason)
        }
        return SigningTarget(url: realURL, isSandboxed: sandboxed,
                             identity: try DataPathIdentity.capture(realURL),
                             fingerprint: try SignatureSnapshot.fingerprint(of: realURL),
                             temporarySpaceRequirement: try CodeSigner.temporarySpaceRequirement(appURL: realURL))
    }
}
