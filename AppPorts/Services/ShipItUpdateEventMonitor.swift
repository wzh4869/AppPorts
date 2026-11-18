import CoreServices
import Foundation

/// Watch the cache parent so a ShipIt directory can be created or replaced after startup.
final class ShipItUpdateEventMonitor: @unchecked Sendable {
    private let caches: URL
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let watchedFiles: Set<String>
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.shipitEvents")
    private var stream: FSEventStreamRef?
    private var directories: Set<String> = []

    init(caches: URL, latency: TimeInterval = 1, watchedFiles: [URL] = [], onChange: @escaping @Sendable () -> Void) {
        self.caches = URL(fileURLWithPath: Self.canonicalFilePath(for: caches))
        self.latency = latency; self.onChange = onChange
        self.watchedFiles = Set(watchedFiles.map { Self.canonicalFilePath(for: $0) })
    }

    private static func canonicalFilePath(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        if let resolved = DiskUtility.resolvedPath(standardized.path) {
            return resolved
        }
        var current = standardized
        var trailingComponents: [String] = []
        while current.path != "/" {
            let name = current.lastPathComponent
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            trailingComponents.append(name)
            current = parent
            if let resolvedAncestor = DiskUtility.resolvedPath(current.path) {
                var rebuilt = URL(fileURLWithPath: resolvedAncestor)
                for component in trailingComponents.reversed() {
                    rebuilt.appendPathComponent(component)
                }
                return rebuilt.standardizedFileURL.path
            }
        }
        return standardized.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @discardableResult
    func start(identifiers: Set<String>) -> Bool {
        queue.sync {
            directories = Set(identifiers.map { $0 + ".ShipIt" })
            if stream != nil { return true }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, context, count, paths, flags, _ in
                guard let context else { return }
                let monitor = Unmanaged<ShipItUpdateEventMonitor>.fromOpaque(context).takeUnretainedValue()
                let values = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
                if (0..<count).contains(where: { monitor.accepts(path: values[$0], flags: flags[$0]) }) {
                    monitor.onChange()
                }
            }, &context, Array(Set([caches.path] + watchedFiles.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency, UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot)) else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created); FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func accepts(path: String, flags: FSEventStreamEventFlags) -> Bool {
        if watchedFiles.contains(path) { return true }
        // Coalesced/dropped events require checking current state, never trusting event details.
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagRootChanged)
        if flags & rescan != 0 { return true }
        let prefix = caches.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/")
        guard let first = parts.first, directories.contains(String(first)) else { return false }
        if parts.count == 1 {
            let replacement = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            return flags & replacement != 0
        }
        return parts.count == 2 && ["ShipItState.plist", "ShipIt_stderr.log"].contains(String(parts[1]))
    }

    deinit { stop() }
}
