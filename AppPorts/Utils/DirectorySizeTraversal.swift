import Darwin
import Foundation

/// Display-only logical sizes. Never use this traversal to authorize copying,
/// verification or deletion; it intentionally does not read file contents.
enum DirectorySizeTraversal {
    static func measure(at root: URL, skippingDirectories: Set<URL> = []) -> DirectorySizeResult {
        measure(at: root, skippingDirectories: skippingDirectories, subtrees: []).root
    }

    static func measure(
        at root: URL,
        skippingDirectories: Set<URL> = [],
        subtrees: Set<URL> = [],
        onSubtreeFinished: ((URL, DirectorySizeResult) -> Void)? = nil
    ) -> (root: DirectorySizeResult, subtrees: [URL: DirectorySizeResult]) {
        let rootURL = root.standardizedFileURL
        var result = DirectorySizeResult()
        var subtreeMap: [String: URL] = [:]
        var subtreeResults: [URL: DirectorySizeResult] = [:]
        for subtree in subtrees {
            subtreeMap[subtree.standardizedFileURL.path] = subtree
            subtreeResults[subtree] = DirectorySizeResult()
        }
        let skippedPaths = Set(skippingDirectories.map { $0.standardizedFileURL.path })

        let needsDirectoryPaths = !skippedPaths.isEmpty || !subtreeMap.isEmpty
        typealias Subtree = (url: URL, level: Int16, startBytes: Int64)
        var activeSubtrees: [Subtree] = []

        // In a depth-first walk each subtree occupies one contiguous range of the root total.
        func finish(_ subtree: Subtree) {
            subtreeResults[subtree.url, default: DirectorySizeResult()].bytes = result.bytes - subtree.startBytes
        }

        func appendIssue(_ issue: DataDirReadIssue, exactSubtree: URL? = nil) {
            result.readIssues.append(issue)
            var targets = Set(activeSubtrees.map(\.url))
            if let exactSubtree { targets.insert(exactSubtree) }
            for target in targets {
                subtreeResults[target, default: DirectorySizeResult()].readIssues.append(issue)
            }
        }

        func propagateFailure(_ error: Error) -> (root: DirectorySizeResult, subtrees: [URL: DirectorySizeResult]) {
            let issue = DataDirReadIssue(url: rootURL, error: error)
            result.readIssues.append(issue)
            for target in subtreeResults.keys {
                subtreeResults[target, default: DirectorySizeResult()].readIssues.append(DataDirReadIssue(url: target, error: error))
            }
            return (result, subtreeResults)
        }

        guard !Task.isCancelled else {
            return propagateFailure(CancellationError())
        }
        // fts owns its traversal state, but borrows the root argument until
        // close. NOCHDIR keeps simultaneous scans from changing process cwd.
        guard let path = root.withUnsafeFileSystemRepresentation({ value in value.flatMap { strdup($0) } }) else {
            return propagateFailure(POSIXError(.ENOMEM))
        }
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let traversal = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return propagateFailure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        defer { fts_close(traversal) }
        var rootDevice: dev_t?
        while true {
            guard !Task.isCancelled else {
                appendIssue(.init(url: rootURL, error: CancellationError()))
                activeSubtrees.forEach(finish)
                return (result, subtreeResults)
            }
            // fts_read reports terminal traversal failures through errno.
            // Clear it here so a skipped child cannot become a root failure.
            errno = 0
            guard let node = fts_read(traversal) else {
                if errno != 0 {
                    appendIssue(.init(url: rootURL, error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
                }
                activeSubtrees.forEach(finish)
                return (result, subtreeResults)
            }
            let entry = node.pointee
            if entry.fts_level == 0, entry.fts_info == FTS_D, onSubtreeFinished != nil {
                rootDevice = entry.fts_statp?.pointee.st_dev
            }
            while let last = activeSubtrees.last, last.level >= entry.fts_level {
                finish(last)
                // XDEV also emits a postorder directory for a mount it never entered.
                if let onSubtreeFinished, entry.fts_info == FTS_DP, last.level == entry.fts_level,
                   let rootDevice, entry.fts_statp?.pointee.st_dev == rootDevice,
                   let finished = subtreeResults[last.url] {
                    onSubtreeFinished(last.url, finished)
                }
                activeSubtrees.removeLast()
            }
            switch Int32(entry.fts_info) {
            case FTS_D, FTS_DNR:
                if entry.fts_info == FTS_D, !needsDirectoryPaths { continue }
                let url = URL(fileURLWithFileSystemRepresentation: entry.fts_path,
                    isDirectory: true, relativeTo: nil).standardizedFileURL
                if skippedPaths.contains(url.path) {
                    if Int32(entry.fts_info) == FTS_D { fts_set(traversal, node, FTS_SKIP) }
                    continue
                }
                let matchedSubtree = subtreeMap[url.path]
                if Int32(entry.fts_info) == FTS_DNR {
                    let code = entry.fts_errno == 0 ? EIO : entry.fts_errno
                    if entry.fts_level > 0 && code == ENOENT { continue }
                    appendIssue(.init(url: url, error: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)),
                                exactSubtree: matchedSubtree)
                } else if let matchedSubtree {
                    activeSubtrees.append((matchedSubtree, entry.fts_level, result.bytes))
                }
            case FTS_F:
                guard let info = entry.fts_statp else {
                    appendIssue(.init(url: rootURL, error: POSIXError(.EIO)))
                    continue
                }
                result.bytes += info.pointee.st_size
            case FTS_ERR, FTS_NS, FTS_DC:
                let code = entry.fts_errno == 0 ? EIO : entry.fts_errno
                // Active apps can remove a temporary child during discovery.
                if entry.fts_level > 0 && code == ENOENT { continue }
                let url = URL(fileURLWithFileSystemRepresentation: entry.fts_path,
                    isDirectory: entry.fts_info == FTS_DNR, relativeTo: nil).standardizedFileURL
                appendIssue(.init(url: url, error: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)),
                            exactSubtree: subtreeMap[url.path])
            default:
                // Directories have no content bytes of their own. PHYSICAL
                // reports symlinks without following them, including cycles.
                continue
            }
        }
    }
}
