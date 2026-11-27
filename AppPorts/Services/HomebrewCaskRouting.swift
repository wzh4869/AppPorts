import CryptoKit
import Darwin
import Foundation

/// All mutations run under AppPorts' operation lock. The saved intent precedes both
/// Homebrew writes and survives Homebrew replacing its versioned directory on upgrade.
struct HomebrewCaskRouting {
    struct Registration: Codable {
        let local: URL
        var external: URL
        let cask: URL
        let caskroomIdentity: DataPathIdentity
        let originalTarget: URL
        let originalExplicit: String?
        let volume: URL
        let volumeUUID: String
        let bundleID: String

        var entry: URL {
            let directory = external.deletingLastPathComponent()
            let relative = directory.pathComponents.dropFirst(volume.pathComponents.count).joined(separator: "/")
            return volume.appendingPathComponent(".appports-brew")
                .appendingPathComponent(volumeUUID + "-" + HomebrewCaskRouting.key(relative))
        }
        var routed: URL { entry.appendingPathComponent(local.lastPathComponent) }
    }

    let caskrooms: [URL]
    let recordsDirectory: URL
    var recycle: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    private let fm = FileManager.default

    static var system: Self? {
        guard NSClassFromString("XCTestCase") == nil, NSClassFromString("XCTest.XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        let support = AppTransferStore.shared.directoryURL.deletingLastPathComponent()
        return .init(caskrooms: ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"].map { URL(fileURLWithPath: $0) },
                     recordsDirectory: support.appendingPathComponent("homebrew-casks"))
    }

    private static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Foundation can standardize a missing leaf differently from the same existing file.
    // A cask receipt must remain addressable after Homebrew removes the bundle.
    static func localPath(_ url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.appendingPathComponent(url.lastPathComponent).path
    }

    private func recordURL(_ local: URL) -> URL {
        recordsDirectory.appendingPathComponent(Self.key(Self.localPath(local)) + ".json")
    }

    private func read(_ file: URL) throws -> Registration {
        let record = try JSONDecoder().decode(Registration.self, from: HomebrewCaskInstallation.regularData(file))
        guard recordURL(record.local).path == file.path, record.local.pathExtension == "app",
              record.local.lastPathComponent == record.external.lastPathComponent,
              caskrooms.contains(where: { $0.path == record.cask.deletingLastPathComponent().path }),
              record.external.path.hasPrefix(record.volume.path + "/"), record.volume.deletingLastPathComponent().path == "/Volumes",
              Self.localPath(record.originalTarget) == Self.localPath(record.local),
              UUID(uuidString: record.volumeUUID) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    func savedRegistration(local: URL) throws -> Registration? {
        let file = recordURL(local)
        guard try AppTransferStore.exists(file) else { return nil }
        return try read(file)
    }

    private func recordFiles() throws -> [URL] {
        guard try AppTransferStore.exists(recordsDirectory) else { return [] }
        guard HomebrewCaskInstallation.realDirectory(recordsDirectory) else { throw CocoaError(.fileReadInvalidFileName) }
        return try fm.contentsOfDirectory(at: recordsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    func registrations() throws -> [Registration] {
        try recordFiles().compactMap { file in
            do { return try read(file) }
            catch {
                AppLogger.shared.logError("读取 Homebrew 应用位置记录失败", error: error, relatedURLs: [("record", file)])
                return nil
            }
        }
    }

    func inventory() throws -> [HomebrewCaskInstallation] {
        var result: [HomebrewCaskInstallation] = []
        for room in caskrooms where HomebrewCaskInstallation.realDirectory(room) {
            for cask in try fm.contentsOfDirectory(at: room, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                // Broken or older receipts are ineligible. A failure reading one must not block other casks.
                if let installation = try? HomebrewCaskInstallation.load(cask) { result.append(installation) }
            }
        }
        return result
    }

    private func ensureEntry(_ record: Registration) throws {
        let parent = record.entry.deletingLastPathComponent()
        if mkdir(parent.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard HomebrewCaskInstallation.realDirectory(parent) else { throw CocoaError(.fileWriteFileExists) }
        let relative = [".."] + record.external.deletingLastPathComponent().pathComponents.dropFirst(record.volume.pathComponents.count)
        let destination = relative.joined(separator: "/")
        if symlink(destination, record.entry.path) != 0 && errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard try fm.destinationOfSymbolicLink(atPath: record.entry.path) == destination,
              record.entry.resolvingSymlinksInPath().path == record.external.deletingLastPathComponent().path else {
            throw CocoaError(.fileWriteFileExists)
        }
    }

    private func verifiedRoom(_ record: Registration) throws {
        let room = record.cask.deletingLastPathComponent()
        guard HomebrewCaskInstallation.realDirectory(room),
              try record.caskroomIdentity.matchesFilesystemObject(DataPathIdentity.capture(room)) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    func register(local: URL, external: URL, installations: () throws -> [HomebrewCaskInstallation]) throws {
        guard local.lastPathComponent == external.lastPathComponent, local.pathExtension == "app",
              HomebrewCaskInstallation.realDirectory(local), HomebrewCaskInstallation.realDirectory(external),
              (try SignatureSnapshot.info(at: external)).st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0,
              AppMigrationService.folderMirrorExternalURL(at: local.deletingLastPathComponent()) == nil,
              AppPortalMaintenance.targetIdentityMatches(localURL: local, externalURL: external),
              let path = try? String(contentsOf: local.appendingPathComponent("Contents/Resources/real_app_path.txt"), encoding: .utf8),
              path.trimmingCharacters(in: .whitespacesAndNewlines) == external.path else { return }
        let values = try external.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
        guard let volume = values.volume, volume.deletingLastPathComponent().path == "/Volumes",
              let uuid = values.volumeUUIDString, UUID(uuidString: uuid) != nil else { return }
        let registration: Registration
        let installation: HomebrewCaskInstallation
        var previous: Registration?
        if let saved = try savedRegistration(local: local) {
            guard saved.volumeUUID == uuid, saved.bundleID == bundleIdentifier(at: external) else { throw CocoaError(.fileWriteFileExists) }
            var updated = saved
            if saved.external.path != external.path {
                // The search-exclusion transaction has committed a same-volume move into AppPorts.noindex.
                let library = AppSearchExclusionService.library(in: saved.external.deletingLastPathComponent())
                guard external.deletingLastPathComponent().path == library.path, try !AppTransferStore.exists(saved.external)
                else { throw CocoaError(.fileWriteFileExists) }
                updated.external = external
                previous = saved
            }
            try verifiedRoom(saved)
            guard let current = try HomebrewCaskInstallation.load(saved.cask) else { throw CocoaError(.fileReadCorruptFile) }
            registration = updated
            installation = current
        } else {
            let matches = try installations().filter { installation in
                guard installation.targetName == local.lastPathComponent,
                      let original = installation.installedTarget,
                      Self.localPath(original) == Self.localPath(local) else { return false }
                return (try? fm.destinationOfSymbolicLink(atPath: installation.source.path)) == original.path
            }
            guard matches.count == 1, let match = matches.first, let original = match.installedTarget,
                  let id = bundleIdentifier(at: external)
            else { return }
            registration = try Registration(local: URL(fileURLWithPath: Self.localPath(local)), external: external, cask: match.directory,
                caskroomIdentity: DataPathIdentity.capture(match.directory.deletingLastPathComponent()),
                originalTarget: original, originalExplicit: match.explicitDirectory, volume: volume, volumeUUID: uuid, bundleID: id)
            try fm.createDirectory(at: recordsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try DurableFileIO.write(JSONEncoder().encode(registration), to: recordURL(local))
            installation = match
        }
        try ensureEntry(registration)
        try installation.redirect(original: registration.originalTarget, routed: registration.routed,
                                  originalExplicit: registration.originalExplicit, restoring: false, previousRoute: previous?.routed)
        if let previous {
            try DurableFileIO.write(JSONEncoder().encode(registration), to: recordURL(local))
            removeUnusedEntry(previous)
        }
    }

    private func bundleIdentifier(at app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    func verifyRestoreSource(local: URL, external: URL) throws {
        guard let record = try savedRegistration(local: local) else { return }
        if record.external.path != external.path {
            try register(local: local, external: external, installations: inventory)
            guard try savedRegistration(local: local)?.external.path == external.path else { throw CocoaError(.fileReadInvalidFileName) }
        }
        guard HomebrewCaskInstallation.realDirectory(external),
              try external.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == record.volumeUUID,
              bundleIdentifier(at: external) == record.bundleID
        else { throw CocoaError(.fileReadInvalidFileName) }
    }

    func restore(local: URL, external: URL) throws {
        guard let record = try savedRegistration(local: local) else { return }
        guard record.external.path == external.path, HomebrewCaskInstallation.realDirectory(local),
              bundleIdentifier(at: local) == record.bundleID
        else { throw CocoaError(.fileReadInvalidFileName) }
        try verifiedRoom(record)
        if try AppTransferStore.exists(record.cask) {
            guard let installation = try HomebrewCaskInstallation.load(record.cask) else { throw CocoaError(.fileReadCorruptFile) }
            try installation.redirect(original: record.originalTarget, routed: record.routed, originalExplicit: record.originalExplicit, restoring: true)
        }
        try forget(record)
    }

    /// The missing bundle alone proves nothing on a removable disk. Only recycle a
    /// signed AppPorts entry after independently observing both removals on their original volumes.
    func retireUninstalled(_ record: Registration) throws -> Bool {
        try verifiedRoom(record)
        guard try !AppTransferStore.exists(record.cask),
              HomebrewCaskInstallation.realDirectory(record.volume),
              try record.volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == record.volumeUUID,
              try !AppTransferStore.exists(record.external) else { return false }
        if try AppTransferStore.exists(record.local) {
            guard HomebrewCaskInstallation.realDirectory(record.local),
                  let plist = NSDictionary(contentsOf: record.local.appendingPathComponent("Contents/Info.plist")),
                  plist["CFBundleIdentifier"] as? String == record.bundleID + ".appports.stub",
                  plist["AppPortsTargetVolumeUUID"] as? String == record.volumeUUID,
                  AppPortalMaintenance.entries(at: record.local).contains(where: { $0.externalURL.path == record.external.path }),
                  try AppTransferTransaction.signatureIsValid(at: record.local) else { return false }
            try recycle(record.local)
        }
        try forget(record)
        return true
    }

    private func forget(_ record: Registration) throws {
        try fm.removeItem(at: recordURL(record.local))
        removeUnusedEntry(record)
    }

    private func removeUnusedEntry(_ record: Registration) {
        // Shared routing links may outlive a cask. Only unlink our exact unused entry.
        guard let remaining = try? recordFiles().map(read), !remaining.contains(where: { $0.entry.path == record.entry.path }),
              (try? record.volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == record.volumeUUID,
              HomebrewCaskInstallation.realDirectory(record.entry.deletingLastPathComponent()),
              (try? fm.destinationOfSymbolicLink(atPath: record.entry.path)) != nil,
              record.entry.resolvingSymlinksInPath().path == record.external.deletingLastPathComponent().path else { return }
        _ = unlink(record.entry.path)
        _ = rmdir(record.entry.deletingLastPathComponent().path)
    }
}
