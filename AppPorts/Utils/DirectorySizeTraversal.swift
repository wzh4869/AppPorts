import Darwin
import Foundation

/// Display-only logical sizes. Never use this traversal to authorize copying,
/// verification or deletion; it intentionally does not read file contents.
enum DirectorySizeTraversal {
    static func measure(at root: URL) -> DirectorySizeResult {
        var result = DirectorySizeResult()
        guard !Task.isCancelled else {
            return DirectorySizeResult(readIssues: [.init(url: root, error: CancellationError())])
        }
        // fts owns its traversal state, but borrows the root argument until
        // close. NOCHDIR keeps simultaneous scans from changing process cwd.
        guard let path = root.withUnsafeFileSystemRepresentation({ value in value.flatMap { strdup($0) } }) else {
            return DirectorySizeResult(readIssues: [.init(url: root, error: POSIXError(.ENOMEM))])
        }
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let traversal = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return DirectorySizeResult(readIssues: [.init(url: root,
                error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))])
        }
        defer { fts_close(traversal) }
        while true {
            guard !Task.isCancelled else {
                result.readIssues.append(.init(url: root, error: CancellationError()))
                return result
            }
            // fts_read reports terminal traversal failures through errno.
            // Clear it here so a skipped child cannot become a root failure.
            errno = 0
            guard let node = fts_read(traversal) else {
                if errno != 0 {
                    result.readIssues.append(.init(url: root,
                        error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
                }
                return result
            }
            let entry = node.pointee
            switch Int32(entry.fts_info) {
            case FTS_F:
                guard let info = entry.fts_statp else {
                    result.readIssues.append(.init(url: root, error: POSIXError(.EIO)))
                    continue
                }
                result.bytes += info.pointee.st_size
            case FTS_DNR, FTS_ERR, FTS_NS, FTS_DC:
                let code = entry.fts_errno == 0 ? EIO : entry.fts_errno
                // Active apps can remove a temporary child during discovery.
                if entry.fts_level > 0 && code == ENOENT { continue }
                let url = URL(fileURLWithFileSystemRepresentation: entry.fts_path,
                    isDirectory: entry.fts_info == FTS_DNR, relativeTo: nil)
                result.readIssues.append(.init(url: url,
                    error: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)))
            default:
                // Directories have no content bytes of their own. PHYSICAL
                // reports symlinks without following them, including cycles.
                continue
            }
        }
    }
}
