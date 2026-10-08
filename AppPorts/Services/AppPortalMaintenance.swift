import Foundation

extension Notification.Name {
    static let appPortalPresentationDidChange = Notification.Name("AppPorts.portalPresentationDidChange")
}

/// Rescans consult the portal's recorded target, never a same-named search result.
enum AppPortalMaintenance {
    struct Entry: Equatable, Sendable {
        let localURL: URL
        let externalURL: URL
    }

    static func entries(at localURL: URL) -> [Entry] {
        let fm = FileManager.default
        // A suite is traversed only when it carries an AppPorts marker. An
        // unrelated app (including Xcode) is never recursively treated as a suite.
        if AppMigrationService.folderMirrorExternalURL(at: localURL) != nil,
           (try? localURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
           let children = try? fm.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil) {
            return children.filter { $0.pathExtension == "app" }.flatMap { entries(at: $0) }
        }
        guard localURL.pathExtension == "app", AppMigrationService().isManagedPortal(at: localURL) else { return [] }
        let target: URL?
        if let raw = try? String(contentsOf: localURL.appendingPathComponent("Contents/Resources/real_app_path.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), raw.hasPrefix("/") {
            target = URL(fileURLWithPath: raw)
        } else if let raw = try? fm.destinationOfSymbolicLink(atPath: localURL.path) {
            target = URL(fileURLWithPath: raw, relativeTo: localURL.deletingLastPathComponent()).standardizedFileURL
        } else {
            target = try? CodeSigner.resolveAppURL(at: localURL)
        }
        guard let target, target.standardizedFileURL != localURL.standardizedFileURL else { return [] }
        return [Entry(localURL: localURL.standardizedFileURL, externalURL: target.standardizedFileURL)]
    }

    /// Safe to call from a scan: records surviving entries but never creates one.
    static func rememberEntries(at localURL: URL, explicitOperation: Bool = false,
                                store: AppSearchRecordStore = .shared) throws {
        for entry in entries(at: localURL) {
            try store.record(name: entry.localURL.deletingPathExtension().lastPathComponent,
                             localURL: entry.localURL, externalURL: entry.externalURL,
                             expectsLocalEntry: true, explicitOperation: explicitOperation)
        }
    }

    static func recordDeletion(at localURL: URL, store: AppSearchRecordStore = .shared) throws {
        let components = localURL.standardizedFileURL.pathComponents
        for record in try store.records() where URL(fileURLWithPath: record.localPath).pathComponents.starts(with: components) {
            try store.setExpectedPresence(localURL: URL(fileURLWithPath: record.localPath), present: false)
        }
    }

    static func recordCompletedTransfer(_ transfer: AppListTransfer, store: AppSearchRecordStore = .shared) throws {
        switch transfer {
        case let .movedOut(app, _, _):
            try rememberEntries(at: app.path, explicitOperation: true, store: store)
        case let .linkedIn(_, destination):
            try rememberEntries(at: destination, explicitOperation: true, store: store)
        case let .movedBack(app, destination, remains, retired):
            let localApps: [URL]
            if app.usesFolderOperation {
                localApps = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "app" }
            } else { localApps = [destination] }
            for old in retired { try recordDeletion(at: old, store: store) }
            for local in localApps {
                let external = app.usesFolderOperation ? app.path.appendingPathComponent(local.lastPathComponent) : app.path
                try store.record(name: local.deletingPathExtension().lastPathComponent, localURL: local,
                                 externalURL: external, expectsLocalEntry: true, explicitOperation: true)
                try store.markRestored(localURL: local, remainingExternal: remains)
            }
        }
    }

    /// Stored volume identity remains authoritative after remounting at the same path.
    static func matchesRememberedTarget(_ entry: Entry, store: AppSearchRecordStore = .shared) -> Bool {
        guard let records = try? store.records() else { return false }
        guard let record = records.first(where: { $0.localPath == entry.localURL.path }) else { return true }
        guard record.externalPath == entry.externalURL.path else { return false }
        if let uuid = record.volumeUUID {
            return (try? entry.externalURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid
        }
        return true
    }

    static func refreshEntries(at localURL: URL, expectedGeneration: UInt64, force: Bool = false,
                               store: AppSearchRecordStore = .shared) -> (updated: Int, skipped: Int) {
        var updated = 0
        var skipped = 0
        for entry in entries(at: localURL) {
            do {
                try store.record(name: entry.localURL.deletingPathExtension().lastPathComponent,
                                 localURL: entry.localURL, externalURL: entry.externalURL, expectsLocalEntry: true)
            } catch {
                AppLogger.shared.logError("保存应用搜索记录失败", error: error)
                skipped += 1
                continue
            }
            guard matchesRememberedTarget(entry, store: store),
                  targetIdentityMatches(localURL: entry.localURL, externalURL: entry.externalURL) else {
                skipped += 1
                continue
            }
            if AppMigrationService().refreshStubPortal(at: entry.localURL, from: entry.externalURL,
                    force: force, expectedGeneration: expectedGeneration) {
                updated += 1
                NotificationCenter.default.post(name: .appPortalPresentationDidChange, object: entry.localURL)
            } else if force { skipped += 1 }
        }
        return (updated, skipped)
    }

    static func targetIdentityMatches(localURL: URL, externalURL: URL) -> Bool {
        guard let local = plist(at: localURL), let external = plist(at: externalURL),
              let actualID = external["CFBundleIdentifier"] as? String, !actualID.isEmpty else { return false }
        let expectedID: String?
        if let recorded = local["AppPortsTargetBundleIdentifier"] as? String {
            expectedID = recorded
        } else if let stub = local["CFBundleIdentifier"] as? String, stub.hasSuffix(".appports.stub") {
            expectedID = String(stub.dropLast(".appports.stub".count))
        } else { return false }
        guard expectedID == actualID else { return false }
        if let uuid = local["AppPortsTargetVolumeUUID"] as? String {
            guard (try? externalURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid else { return false }
        }
        return true
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
