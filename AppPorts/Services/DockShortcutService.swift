import CoreFoundation
import Darwin
import Foundation

/// Repairs existing Dock tiles after an application moves. Never adds or removes a tile.
final class DockShortcutService: @unchecked Sendable {
    struct Store {
        let read: () throws -> Any?
        let write: ([[String: Any]]) throws -> Void
        let isManaged: () -> Bool

        static let currentUser = Store(
            read: {
                guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                    throw ShortcutError.preferencesReadFailed
                }
                return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            },
            write: { tiles in
                guard !preferencesAreManaged() else { throw ShortcutError.managedPreferences }
                CFPreferencesSetValue(key, tiles as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                    throw ShortcutError.preferencesWriteFailed
                }
            },
            isManaged: preferencesAreManaged
        )

        private static let domain = "com.apple.dock" as CFString
        private static let key = "persistent-apps" as CFString

        private static func preferencesAreManaged() -> Bool {
            if CFPreferencesAppValueIsForced(key, domain)
                || CFPreferencesAppValueIsForced("static-apps" as CFString, domain) {
                return true
            }
            return ["contents-immutable", "static-only"].contains { name in
                (CFPreferencesCopyAppValue(name as CFString, domain) as? Bool) == true
            }
        }
    }

    struct Bookmarks {
        let create: (URL) throws -> Data
        let resolve: (Data) throws -> URL

        static let fileSystem = Bookmarks(
            create: { try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) },
            resolve: { data in
                var stale = false
                return try URL(
                    resolvingBookmarkData: data,
                    options: [.withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            }
        )
    }

    enum ShortcutError: Error, CustomNSError {
        case invalidLocalURL
        case malformedPreferences
        case managedPreferences
        case destinationUnavailable
        case invalidBundleIdentifier
        case bookmarkMismatch
        case preferencesReadFailed
        case preferencesWriteFailed
        case concurrentModification
        case verificationFailed

        static let errorDomain = "com.appports.DockShortcutService"

        var errorCode: Int {
            switch self {
            case .invalidLocalURL: return 1
            case .malformedPreferences: return 2
            case .managedPreferences: return 3
            case .destinationUnavailable: return 4
            case .invalidBundleIdentifier: return 5
            case .bookmarkMismatch: return 6
            case .preferencesReadFailed: return 7
            case .preferencesWriteFailed: return 8
            case .concurrentModification: return 9
            case .verificationFailed: return 10
            }
        }

        var errorUserInfo: [String: Any] {
            let description: String
            switch self {
            case .invalidLocalURL: description = "Dock shortcuts require absolute local file URLs."
            case .malformedPreferences: description = "The Dock application list has an unsupported or malformed format."
            case .managedPreferences: description = "The Dock application list is managed or locked."
            case .destinationUnavailable: description = "The destination application is unavailable."
            case .invalidBundleIdentifier: description = "The destination has no valid original application identifier."
            case .bookmarkMismatch: description = "The new Dock bookmark does not resolve to the destination application."
            case .preferencesReadFailed: description = "The Dock application list could not be read."
            case .preferencesWriteFailed: description = "The Dock application list could not be saved."
            case .concurrentModification: description = "The Dock application list kept changing. Please try again."
            case .verificationFailed: description = "The saved Dock application list could not be verified."
            }
            return [NSLocalizedDescriptionKey: description]
        }
    }

    static let shared = DockShortcutService(
        store: .currentUser,
        reload: { ReloadScheduler.shared.schedule() }
    )

    private let store: Store
    private let bookmarks: Bookmarks
    private let applicationIdentifier: (URL) throws -> String
    private let reload: () -> Void
    private let lock = NSLock()
    private static let dateCacheKeys = ["file-mod-date", "parent-mod-date", "file-mod-date-hi", "parent-mod-date-hi"]

    /// Inject all effects in tests; the default bookmark codec only accesses the supplied file URLs.
    init(
        store: Store,
        bookmarks: Bookmarks = .fileSystem,
        applicationIdentifier: ((URL) throws -> String)? = nil,
        reload: @escaping () -> Void
    ) {
        self.store = store
        self.bookmarks = bookmarks
        self.applicationIdentifier = applicationIdentifier ?? Self.readApplicationIdentifier
        self.reload = reload
    }

    /// Inspects existing pins without creating bookmarks, saving preferences, or reloading Dock.
    func needsRedirect(from sourceRootURL: URL, to destinationRootURL: URL, requiringBundleIdentity: Bool = true) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let source = try LocalPath(sourceRootURL)
        let destination = try LocalPath(destinationRootURL)
        let snapshot = try readSnapshot()
        let candidates = try matchingTiles(in: snapshot, source: source, destination: destination)
        var needsUpdate = false
        for candidate in candidates {
            let data = snapshot[candidate.index]["tile-data"] as! [String: Any]
            let target = candidate.destination.url
            let identifier = try validatedIdentifier(for: data, at: target, requiringBundleIdentity: requiringBundleIdentity)
            // Inspect every candidate so an earlier incomplete pin cannot hide an identity conflict.
            if !isCurrent(data, at: target, identifier: identifier) { needsUpdate = true }
        }
        return needsUpdate
    }

    @discardableResult
    func redirectShortcuts(from sourceRootURL: URL, to destinationRootURL: URL, requiringBundleIdentity: Bool = false) throws -> Int {
        do {
            let count = try redirectWhileLocked(from: sourceRootURL, to: destinationRootURL, requiringBundleIdentity: requiringBundleIdentity)
            if count > 0 {
                AppLogger.shared.logContext("已更新 Dock 固定项", details: [
                    ("source", sourceRootURL.path), ("destination", destinationRootURL.path),
                    ("updated_count", String(count))
                ])
                reload()
            }
            return count
        } catch {
            AppLogger.shared.logError("更新 Dock 固定项失败", error: error, context: [
                ("source", sourceRootURL.path), ("destination", destinationRootURL.path)
            ])
            throw error
        }
    }

    private func redirectWhileLocked(from sourceURL: URL, to destinationURL: URL, requiringBundleIdentity: Bool) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let source = try LocalPath(sourceURL)
        let destination = try LocalPath(destinationURL)
        var snapshot = try readSnapshot()

        // CFPreferences has no compare-and-swap. Rebase on fresh snapshots, without attempting
        // a rollback that could overwrite a subsequent user edit.
        for _ in 0..<3 {
            let candidates = try matchingTiles(in: snapshot, source: source, destination: destination)
            guard !candidates.isEmpty else { return 0 }
            guard !store.isManaged() else { throw ShortcutError.managedPreferences }
            var updated = snapshot
            var count = 0
            for candidate in candidates {
                let target = candidate.destination.url
                var tile = updated[candidate.index]
                var data = tile["tile-data"] as! [String: Any]
                var file = data["file-data"] as! [String: Any]
                let identifier = try validatedIdentifier(for: data, at: target, requiringBundleIdentity: requiringBundleIdentity)

                if isCurrent(data, at: target, identifier: identifier) {
                    continue
                }

                let book = try bookmarks.create(target)
                guard Self.sameDestination(try bookmarks.resolve(book), target) else {
                    throw ShortcutError.bookmarkMismatch
                }
                file["_CFURLString"] = target.absoluteString
                file["_CFURLStringType"] = 15
                data["file-data"] = file
                data["bundle-identifier"] = identifier
                data["book"] = book
                Self.dateCacheKeys.forEach { data.removeValue(forKey: $0) }
                tile["tile-data"] = data
                updated[candidate.index] = tile
                count += 1
            }
            guard count > 0 else { return 0 }

            let fresh = try readSnapshot()
            guard Self.equal(snapshot, fresh) else {
                snapshot = fresh
                continue
            }
            guard !store.isManaged() else { throw ShortcutError.managedPreferences }
            try store.write(updated)
            guard Self.equal(updated, try readSnapshot()) else { throw ShortcutError.verificationFailed }
            return count
        }
        throw ShortcutError.concurrentModification
    }

    private func validatedIdentifier(for data: [String: Any], at target: URL, requiringBundleIdentity: Bool) throws -> String {
        let identifier = try applicationIdentifier(target)
        guard Self.isOriginalIdentifier(identifier) else { throw ShortcutError.invalidBundleIdentifier }
        // A retry inferred from storage layout has no authoritative old-path record.
        // Require the existing pin's identity before changing it; a name match is insufficient.
        if requiringBundleIdentity {
            let previousID = data["bundle-identifier"] as? String
            guard previousID == identifier || previousID == identifier + ".appports.stub" else {
                throw ShortcutError.invalidBundleIdentifier
            }
        }
        return identifier
    }

    private func isCurrent(_ data: [String: Any], at target: URL, identifier: String) -> Bool {
        let file = data["file-data"] as! [String: Any]
        guard file["_CFURLString"] as? String == target.absoluteString,
              file["_CFURLStringType"] as? Int == 15,
              data["bundle-identifier"] as? String == identifier,
              let book = data["book"] as? Data,
              let resolved = try? bookmarks.resolve(book) else { return false }
        return Self.sameDestination(resolved, target)
    }

    private struct Candidate {
        let index: Int
        let destination: LocalPath
    }

    private func readSnapshot() throws -> [[String: Any]] {
        guard let value = try store.read() else { return [] }
        guard let tiles = value as? [[String: Any]],
              PropertyListSerialization.propertyList(tiles, isValidFor: .binary) else {
            throw ShortcutError.malformedPreferences
        }
        for tile in tiles {
            guard let type = tile["tile-type"] as? String else { throw ShortcutError.malformedPreferences }
            guard type == "file-tile" else { continue }
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  (try? Self.path(from: file)) != nil,
                  data["book"] == nil || data["book"] is Data,
                  data["bundle-identifier"] == nil || data["bundle-identifier"] is String else {
                throw ShortcutError.malformedPreferences
            }
        }
        return tiles
    }

    private func matchingTiles(in tiles: [[String: Any]], source: LocalPath, destination: LocalPath) throws -> [Candidate] {
        var result: [Candidate] = []
        for (index, tile) in tiles.enumerated() where tile["tile-type"] as? String == "file-tile" {
            let data = tile["tile-data"] as! [String: Any]
            let file = data["file-data"] as! [String: Any]
            let path = try Self.path(from: file)
            // Match file-data before resolving bookmarks: a bookmark can already follow the
            // moved file while this URL still identifies the old local Dock entry.
            if let suffix = path.applicationSuffix(relativeTo: source) {
                result.append(Candidate(index: index, destination: destination.appending(suffix)))
            } else if let identifier = data["bundle-identifier"] as? String,
                      identifier.hasSuffix(".appports.stub"),
                      path.applicationSuffix(relativeTo: destination) != nil {
                result.append(Candidate(index: index, destination: path))
            }
        }
        return result
    }

    /// Older Dock tiles store an absolute POSIX path (type 0), not an encoded URL (type 15).
    private static func path(from file: [String: Any]) throws -> LocalPath {
        guard let string = file["_CFURLString"] as? String,
              let number = file["_CFURLStringType"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let type = file["_CFURLStringType"] as? Int else {
            throw ShortcutError.malformedPreferences
        }
        switch type {
        case 0:
            guard string.hasPrefix("/"), !string.contains("\0"),
                  !string.split(separator: "/").contains("..") else {
                throw ShortcutError.malformedPreferences
            }
            return try LocalPath(URL(fileURLWithPath: string, isDirectory: false))
        case 15:
            guard let url = URL(string: string) else { throw ShortcutError.malformedPreferences }
            return try LocalPath(url)
        default:
            throw ShortcutError.malformedPreferences
        }
    }

    private static func equal(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        (lhs as NSArray).isEqual(rhs as NSArray)
    }

    /// Pure lexical normalization. In particular, never resolve the source's symlink identity.
    private struct LocalPath {
        let components: [String]
        var url: URL { URL(fileURLWithPath: "/" + components.joined(separator: "/")) }

        init(_ url: URL) throws {
            guard url.baseURL == nil, url.isFileURL,
                  let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parsed.host == nil || parsed.host == "" || parsed.host == "localhost",
                  parsed.user == nil, parsed.password == nil, parsed.port == nil,
                  parsed.query == nil, parsed.fragment == nil,
                  let path = parsed.percentEncodedPath.removingPercentEncoding,
                  path.hasPrefix("/"), !path.contains("\0") else {
                throw ShortcutError.invalidLocalURL
            }
            var normalized: [String] = []
            for part in path.split(separator: "/").map(String.init) {
                if part == "." { continue }
                // Collapsing '..' across a symlink parent can identify a different file.
                guard part != ".." else { throw ShortcutError.invalidLocalURL }
                normalized.append(part)
            }
            guard !normalized.isEmpty else { throw ShortcutError.invalidLocalURL }
            components = normalized
        }

        private init(components: [String]) { self.components = components }

        func appending(_ suffix: [String]) -> LocalPath {
            LocalPath(components: components + suffix)
        }

        func applicationSuffix(relativeTo root: LocalPath) -> [String]? {
            guard components.last?.lowercased().hasSuffix(".app") == true,
                  components.starts(with: root.components) else { return nil }
            if components.count == root.components.count { return [] }
            // A .app is one launch target, not a suite directory containing helper apps.
            guard root.components.last?.lowercased().hasSuffix(".app") != true else { return nil }
            return Array(components.dropFirst(root.components.count))
        }
    }

    private static func sameDestination(_ resolved: URL, _ target: URL) -> Bool {
        guard let localResolved = try? LocalPath(resolved), let localTarget = try? LocalPath(target),
              let actual = try? LocalPath(localResolved.url.resolvingSymlinksInPath()),
              let expected = try? LocalPath(localTarget.url.resolvingSymlinksInPath()) else { return false }
        return actual.components == expected.components
    }

    private static func isOriginalIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.hasSuffix(".appports.stub")
    }

    private static func readApplicationIdentifier(at url: URL) throws -> String {
        var directory: ObjCBool = false
        guard url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw ShortcutError.destinationUnavailable
        }
        for path in ["Contents/Info.plist", "Info.plist", "WrappedBundle/Info.plist", "WrappedBundle/Contents/Info.plist"] {
            if let identifier = plist(at: url.appendingPathComponent(path))?["CFBundleIdentifier"] as? String {
                guard isOriginalIdentifier(identifier) else { throw ShortcutError.invalidBundleIdentifier }
                return identifier
            }
        }
        let wrapper = url.appendingPathComponent("Wrapper", isDirectory: true)
        if let children = try? FileManager.default.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil) {
            let identifiers = children.filter { $0.pathExtension.lowercased() == "app" }.compactMap { child in
                (plist(at: child.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String)
                    ?? (plist(at: child.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String)
            }
            if identifiers.count == 1, let identifier = identifiers.first, isOriginalIdentifier(identifier) {
                return identifier
            }
        }
        for path in ["iTunesMetadata.plist", "Wrapper/iTunesMetadata.plist", "WrappedBundle/iTunesMetadata.plist"] {
            if let identifier = plist(at: url.appendingPathComponent(path))?["softwareVersionBundleId"] as? String,
               isOriginalIdentifier(identifier) {
                return identifier
            }
        }
        throw ShortcutError.invalidBundleIdentifier
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Coalesces suite/batch updates without blocking the caller or signalling another user's Dock.
    final class ReloadScheduler: @unchecked Sendable {
        static let shared = ReloadScheduler(action: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-x", "-u", String(getuid()), "Dock"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { child in
                if child.terminationStatus > 1 {
                    AppLogger.shared.logContext("Dock 重载命令失败", details: [("status", String(child.terminationStatus))], level: "WARN")
                }
            }
            try process.run()
        })

        private let queue = DispatchQueue(label: "com.appports.dock-reload")
        private let delay: TimeInterval
        private let action: () throws -> Void
        private var pending: DispatchWorkItem?

        init(delay: TimeInterval = 0.4, action: @escaping () throws -> Void) {
            self.delay = delay
            self.action = action
        }

        func schedule() {
            queue.async { [self] in
                pending?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pending = nil
                    do { try self.action() }
                    catch { AppLogger.shared.logError("无法重载当前用户的 Dock", error: error) }
                }
                pending = work
                queue.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }
}
