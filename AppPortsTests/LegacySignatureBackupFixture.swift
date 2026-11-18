import Foundation
@testable import AppPorts

/// Compatibility fixtures, deliberately available only in the test target.
/// New production signature operations cannot create permanent originals.
extension CodeSigner {
    func backupOriginalSignature(appURL: URL, bundleIdentifier: String) async throws {
        let app = try Self.resolveAppURL(at: appURL)
        let identifier = Self.bundleIdentifier(at: app) ?? bundleIdentifier
        let history = SignatureHistoryStore(backupDirectoryURL: backupDirectoryURL)
        try FileManager.default.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        let fingerprint = try SignatureSnapshot.fingerprint(of: app)
        if let existing = try history.read(bundleIdentifier: identifier),
           existing.restorableFingerprints?.contains(fingerprint) == true { return }
        let snapshotName = "original-" + UUID().uuidString + ".app"
        let snapshot = backupDirectoryURL.appendingPathComponent(snapshotName)
        try SignatureSnapshot.copy(from: app, to: snapshot)
        let backup = SignatureBackup(bundleIdentifier: identifier,
            signingIdentity: await getSigningIdentity(appURL: app) ?? "ad-hoc", originalPath: app.path, backupDate: Date(),
            schemaVersion: 2, snapshotName: snapshotName, originalFingerprint: fingerprint,
            restorableFingerprints: [fingerprint], originalSignatureWasValid: await verify(appURL: app) == .valid)
        try history.write(backup)
    }
}
