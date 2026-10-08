import Foundation

/// Persistent portal identity and lifecycle, independent of Spotlight observations.
enum AppSearchLifecycle: String, Codable, Sendable { case migrated, restored }

struct AppSearchRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String { localPath }
    var name: String
    var localPath: String
    var externalPath: String
    var volumeUUID: String?
    var expectsLocalEntry: Bool
    var lifecycle: AppSearchLifecycle?
    var remainingExternal: Bool?
    var targetBundleIdentifier: String?

    var isRestored: Bool { lifecycle == .restored }
}

/// Atomic durable records survive removal of a portal. A missing record is never permission to create one.
final class AppSearchRecordStore: @unchecked Sendable {
    static let shared = AppSearchRecordStore()
    private let fileURL: URL
    private let lock: NSLock
    private static let registryLock = NSLock()
    private static var locks: [String: NSLock] = [:]

    private static func lock(for url: URL) -> NSLock {
        registryLock.lock(); defer { registryLock.unlock() }
        let path = url.standardizedFileURL.path
        if let lock = locks[path] { return lock }
        let lock = NSLock()
        locks[path] = lock
        return lock
    }

    init(fileURL: URL? = nil) {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
        self.fileURL = fileURL ?? (isTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("AppPorts-search-tests-\(UUID().uuidString).json")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AppPorts/app-search-records.json"))
        lock = Self.lock(for: self.fileURL)
    }

    func records() throws -> [AppSearchRecord] {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }

    func record(name: String, localURL: URL, externalURL: URL, expectsLocalEntry: Bool, explicitOperation: Bool = false) throws {
        try mutate { records in
            let local = localURL.standardizedFileURL.path
            let external = externalURL.standardizedFileURL.path
            let portalPlist = NSDictionary(contentsOf: localURL.appendingPathComponent("Contents/Info.plist"))
            let storedPortalID = portalPlist?["CFBundleIdentifier"] as? String
            let portalID = (portalPlist?["AppPortsTargetBundleIdentifier"] as? String)
                ?? storedPortalID.flatMap { $0.hasSuffix(".appports.stub") ? String($0.dropLast(".appports.stub".count)) : nil }
            let volume = try? externalURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            if let index = records.firstIndex(where: { $0.localPath == local }) {
                var value = records[index]
                value.name = name
                // A newly mounted disk or same-named application is not proof of identity.
                let identityChanged = value.externalPath != external
                    || (value.volumeUUID != nil && volume != nil && value.volumeUUID != volume)
                if !identityChanged || explicitOperation {
                    value.externalPath = external; value.expectsLocalEntry = expectsLocalEntry
                    if let volume { value.volumeUUID = volume }
                    if explicitOperation { value.lifecycle = .migrated; value.remainingExternal = nil }
                    if explicitOperation || value.targetBundleIdentifier == nil {
                        value.targetBundleIdentifier = portalID
                    }
                }
                records[index] = value
            } else {
                records.append(AppSearchRecord(name: name, localPath: local, externalPath: external,
                    volumeUUID: volume, expectsLocalEntry: expectsLocalEntry, targetBundleIdentifier: portalID))
            }
        }
    }

    func setExpectedPresence(localURL: URL, present: Bool) throws {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.localPath == localURL.standardizedFileURL.path }) else { return }
            if records[index].expectsLocalEntry != present {
                records[index].expectsLocalEntry = present
            }
        }
    }

    func markRestored(localURL: URL, remainingExternal: Bool) throws {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.localPath == localURL.standardizedFileURL.path }) else { return }
            records[index].lifecycle = .restored
            records[index].remainingExternal = remainingExternal
            records[index].expectsLocalEntry = true
        }
    }

    /// A directory listing sees broken symlinks too. Access errors and disconnected volumes
    /// must not be interpreted as Finder deletions. Missing suite folders are resolved via
    /// their nearest accessible ancestor; never traverse across /Volumes to infer deletion.
    static func observedLocalPresence(at url: URL, fileManager: FileManager = .default) -> Bool? {
        var child = url.standardizedFileURL
        while child.path != "/" {
            let parent = child.deletingLastPathComponent()
            if parent.path == "/Volumes" { return nil }
            do {
                let names = try fileManager.contentsOfDirectory(atPath: parent.path)
                return names.contains(child.lastPathComponent) ? (child == url.standardizedFileURL ? true : nil) : false
            } catch {
                let error = error as NSError
                guard error.domain == NSCocoaErrorDomain,
                      error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError else { return nil }
                child = parent
            }
        }
        return nil
    }

    func reconcileLocalPresence() throws {
        try mutate { records in
            for index in records.indices {
                guard let present = Self.observedLocalPresence(at: URL(fileURLWithPath: records[index].localPath)),
                      present != records[index].expectsLocalEntry else { continue }
                records[index].expectsLocalEntry = present
            }
        }
    }

    /// Commit path changes only after all surviving portals have been installed. Deleted portals stay deleted.
    func retarget(from source: URL, to destination: URL, snapshots: [AppSearchRecord]) throws {
        try mutate { records in
            let current = records.filter { $0.externalPath == source.path }
            guard current == snapshots else {
                throw AppSearchExclusionService.failure("应用记录已改变，请重新扫描后重试。".localized)
            }
            for index in records.indices where records[index].externalPath == source.path {
                records[index].externalPath = destination.path
            }
        }
    }

    private func read() throws -> [AppSearchRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([AppSearchRecord].self, from: Data(contentsOf: fileURL))
    }

    private func mutate(_ body: (inout [AppSearchRecord]) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var records = try read()
        try body(&records)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
    }
}
