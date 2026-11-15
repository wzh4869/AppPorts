import Foundation

/// ShipIt stores resumable state per host, separately from its downloaded update.
enum ShipItInstallerState {
    static let ownedBundleKey = "SQRLInstallerOwnedBundle"
    static let attemptsKey = "SQRLShipItInstallationAttempts"

    static func clear(for candidate: ShipItUpdateRecovery.Candidate, domain override: String? = nil) throws {
        guard try SignatureRecordFile.data(at: candidate.stateURL) == candidate.requestBytes else {
            throw CocoaError(.fileReadUnknown)
        }
        let domain = (override ?? (candidate.request.bundleIdentifier + ".ShipIt")) as CFString
        if let value = read(ownedBundleKey, domain: domain) {
            guard let data = value as? Data,
                  let archive = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  archive["$archiver"] as? String == "NSKeyedArchiver",
                  let objects = archive["$objects"] as? [Any],
                  objects.compactMap({ $0 as? String }).contains(where: {
                      guard let url = URL(string: $0), url.isFileURL else { return false }
                      return url.standardizedFileURL.path == candidate.request.targetBundleURL.standardizedFileURL.path
                  }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        // No unarchiving: a third-party class must never execute while inspecting this record.
        for key in [ownedBundleKey, attemptsKey] {
            CFPreferencesSetValue(key as CFString, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
              read(ownedBundleKey, domain: domain) == nil, read(attemptsKey, domain: domain) == nil else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func read(_ key: String, domain: CFString) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}
