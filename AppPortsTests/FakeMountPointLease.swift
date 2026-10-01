import Darwin
import Foundation
@testable import AppPorts

/// Only the mapping from virtual mountpoint to hidden physical directory differs
/// from a native mount. Initial local checks still execute the production lease.
final class FakeMountPointLease: MountPointLeasing {
    enum FixtureFailure: LocalizedError {
        case violation(String)
        var errorDescription: String? { switch self { case .violation(let detail): return detail } }
    }
    private let native: MountPointLease
    private let runner: FakeDiskCommandRunner
    private let url: URL
    private let descriptor: Int32
    private let identity: DataPathIdentity

    init(at url: URL, runner: FakeDiskCommandRunner) throws {
        native = try MountPointLease(at: url)
        self.url = url
        self.runner = runner
        identity = try DataPathIdentity.capture(url)
        // The separate synthetic overlay object has writable volume permissions;
        // this retained descriptor continues to inspect the locked local object.
        guard chmod(url.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
        let held = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let locked = chmod(url.path, 0)
        guard held >= 0, locked == 0 else {
            if held >= 0 { close(held) }
            throw POSIXError(.EACCES)
        }
        descriptor = held
    }
    deinit { close(descriptor) }

    func verifyBeforeMount() throws { try native.verifyBeforeMount() }

    func verifyUnderlyingDirectory() throws {
        let physical = runner.physicalUnderlyingPath(for: url)
        guard try DataPathIdentity.capture(physical) == identity else { throw FixtureFailure.violation("Synthetic underlying identity changed: \(physical.path)") }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & 0o7777 == 0 else {
            throw FixtureFailure.violation("Synthetic underlying mode changed: \(attributes.st_mode)")
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard let resolved = realpath(physical.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }
        guard fcntl(descriptor, F_GETPATH, &path) == 0,
              String(cString: path) == String(cString: resolved) else {
            throw FixtureFailure.violation("Synthetic held path \(String(cString: path)) expected \(physical.path)")
        }
        let copy = dup(descriptor)
        guard copy >= 0, let directory = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw POSIXError(.EBADF)
        }
        defer { closedir(directory) }
        rewinddir(directory)
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name == "." || name == ".." else { throw MountPointLease.Failure.notEmpty }
            errno = 0
        }
        guard errno == 0 else { throw POSIXError(.EIO) }
    }
}

struct SyntheticNoWritersRunner: ShellCommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
    }
}
