import Darwin
import Foundation

/// This identity comes from the kernel, not the version currently installed at
/// the executable's path. Replacing an app on disk does not upgrade its process.
struct WriterProcessIdentity: Codable, Equatable, Sendable {
    let processID: Int32
    let userID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
}

struct WriterPresence: Codable, Equatable, Sendable {
    let process: WriterProcessIdentity
    let dataDirectoryPath: String
    let capabilities: Set<String>
}

enum WriterAdmissionError: LocalizedError {
    case incompatibleWriter(WriterProcessIdentity, String)
    case inspectionFailed(Int32?, String)
    case defaultDataInTests

    var errorDescription: String? {
        switch self {
        case let .incompatibleWriter(process, reason):
            return String(format: "仍有无法确认写入兼容性的 AppPorts 进程（PID %@，%@）：%@。请退出该进程后重试；现有副本已保留。".localized,
                          String(process.processID), process.executablePath, reason)
        case let .inspectionFailed(pid, reason):
            if let pid {
                return String(format: "无法确认运行中的 AppPorts 写入进程（PID %@）：%@。已暂停写入并保留现有副本。".localized,
                              String(pid), reason)
            }
            return String(format: "无法确认运行中的 AppPorts 写入进程：%@。已暂停写入并保留现有副本。".localized, reason)
        case .defaultDataInTests:
            return "测试进程不能写入用户的 AppPorts 数据目录；请注入独立测试目录。".localized
        }
    }
}

/// Small, process-lifetime capability registration. This is an admission check
/// for live writers, not a schema/version gate or an operation journal. A stale
/// registration cannot authorize a reused PID or another data directory.
final class WriterAdmission {
    static let requiredCapability = "appports-verified-writer-v8-manual-mount-pause"
    static var defaultDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts", isDirectory: true)
    }

    private static var live: WriterAdmission { WriterAdmission(dataDirectory: defaultDataDirectory) }
    private let dataDirectory: URL
    private let currentProcess: () throws -> WriterProcessIdentity
    private let processSnapshot: () throws -> [WriterProcessIdentity]
    private let clock: () -> TimeInterval
    private let waitForRegistration: (TimeInterval) -> Void

    init(dataDirectory: URL,
         currentProcess: @escaping () throws -> WriterProcessIdentity = { try currentProcessIdentity() },
         processSnapshot: @escaping () throws -> [WriterProcessIdentity] = { try runningAppPortsProcesses() },
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         waitForRegistration: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.dataDirectory = Self.canonical(dataDirectory)
        self.currentProcess = currentProcess
        self.processSnapshot = processSnapshot
        self.clock = clock
        self.waitForRegistration = waitForRegistration
    }

    /// Called before main/--mount-agent startup. XCTest uses injected datasets
    /// and must not create even presence metadata in the user's real dataset.
    static func registerCurrentWriter() throws {
        guard !isRunningUnitTests else { return }
        let admission = live
        try admission.registerCurrentProcess()
        DispatchQueue.global(qos: .utility).async {
            // Create the admission object on this worker; no UI or operation lock is held.
            Self.live.pruneExitedPresences(continueInBatches: true)
        }
    }

    /// Production stores share this one dataset. Injected stores are isolated;
    /// tests of admission itself use an instance with a synthetic process list.
    static func recheck(dataDirectory: URL) throws {
        guard canonical(dataDirectory) == canonical(defaultDataDirectory) else { return }
        guard !isRunningUnitTests else { throw WriterAdmissionError.defaultDataInTests }
        try live.checkCurrentWriters()
    }

    static func prepareForWrite(dataDirectory: URL) throws {
        guard canonical(dataDirectory) == canonical(defaultDataDirectory) else { return }
        guard !isRunningUnitTests else { throw WriterAdmissionError.defaultDataInTests }
        try live.registerCurrentProcess()
        try live.checkCurrentWriters()
    }

    func registerCurrentProcess() throws {
        let process = try currentProcess()
        let presence = WriterPresence(process: process, dataDirectoryPath: dataDirectory.path,
                                      capabilities: [Self.requiredCapability])
        try preparePresenceDirectory()
        if (try? readPresence(processID: process.processID)) == presence { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try DurableFileIO.write(try encoder.encode(presence), to: presenceURL(processID: process.processID))
    }

    /// Claim an entry by atomic rename before deleting it. A publisher can replace
    /// the public name, but can never replace our private, unpredictable claim.
    /// Changed entries are restored without overwriting a concurrent publication.
    /// A brief missing registration still fails closed in checkCurrentWriters.
    func pruneExitedPresences(maximumScanned: Int = 256, maximumRemoved: Int = 64,
                              timeBudget: TimeInterval = 0.02,
                              continueInBatches: Bool = false,
                              hasExited: (Int32) -> Bool = { processHasExited($0) },
                              beforeClaim: (() -> Void)? = nil) {
        guard maximumScanned > 0, maximumRemoved > 0, timeBudget > 0 else { return }
        var started = ProcessInfo.processInfo.systemUptime
        let directory = open(presenceDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { _ = close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o077 == 0 else { return }
        // A separate nonblocking maintenance lock serializes collectors only.
        // Legacy publishers need not participate in this protocol.
        let lock = openat(directory, ".collection-lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return }
        defer { _ = close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(), flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { _ = flock(lock, LOCK_UN) }
        let enumerationDescriptor = dup(directory)
        guard enumerationDescriptor >= 0 else { return }
        guard let stream = fdopendir(enumerationDescriptor) else {
            _ = close(enumerationDescriptor)
            return
        }
        defer { closedir(stream) }
        var scanned = 0
        var removed = 0
        var attempted = 0
        while true {
            if scanned >= maximumScanned || attempted >= maximumRemoved
                || ProcessInfo.processInfo.systemUptime - started >= timeBudget {
                guard continueInBatches else { break }
                // Keep the same directory stream so retained entries cannot
                // starve the tail. Only the utility worker opts into a full sweep.
                Thread.sleep(forTimeInterval: 0.01)
                scanned = 0
                attempted = 0
                started = ProcessInfo.processInfo.systemUptime
            }
            guard let entry = readdir(stream) else { break }
            scanned += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            // Interrupted claims are restored first, including malformed contents.
            if name.hasPrefix(".claim-"), let pid = Self.claimPID(name) {
                _ = renameatx_np(directory, name, directory, String(pid) + ".plist", UInt32(RENAME_EXCL))
                continue
            }
            guard name.hasSuffix(".plist"), let pid = Int32(name.dropLast(6)), pid > 0,
                  name == String(pid) + ".plist", hasExited(pid) else { continue }
            var observed = stat()
            guard fstatat(directory, name, &observed, AT_SYMLINK_NOFOLLOW) == 0,
                  observed.st_mode & S_IFMT == S_IFREG, observed.st_uid == getuid(),
                  observed.st_nlink == 1 else { continue }
            attempted += 1
            beforeClaim?()
            let claim = ".claim-" + String(pid) + "-" + UUID().uuidString
            guard renameatx_np(directory, name, directory, claim, UInt32(RENAME_EXCL)) == 0 else { continue }
            var claimed = stat()
            let unchanged = fstatat(directory, claim, &claimed, AT_SYMLINK_NOFOLLOW) == 0
                && claimed.st_dev == observed.st_dev && claimed.st_ino == observed.st_ino
                && claimed.st_size == observed.st_size
                && claimed.st_mtimespec.tv_sec == observed.st_mtimespec.tv_sec
                && claimed.st_mtimespec.tv_nsec == observed.st_mtimespec.tv_nsec
            if unchanged && hasExited(pid) {
                if unlinkat(directory, claim, 0) == 0 { removed += 1 }
                else { _ = renameatx_np(directory, claim, directory, name, UInt32(RENAME_EXCL)) }
            } else {
                // EEXIST preserves both copies. The next collection retries the
                // claim; it never replaces a newer public registration.
                _ = renameatx_np(directory, claim, directory, name, UInt32(RENAME_EXCL))
            }
        }
        if removed > 0 {
            AppLogger.shared.logContext("回收已退出进程的写入登记", details: [("removed", String(removed))], level: "TRACE")
        }
    }

    private static func claimPID(_ name: String) -> Int32? {
        let fields = name.split(separator: "-", maxSplits: 2)
        guard fields.count == 3, let pid = Int32(fields[1]), pid > 0,
              UUID(uuidString: String(fields[2])) != nil else { return nil }
        return pid
    }

    func checkCurrentWriters() throws {
        var registrationRetries = 0
        while true {
            let processes = try processSnapshot()
            let current = try currentProcess()
            guard processes.contains(current) else {
                throw WriterAdmissionError.inspectionFailed(current.processID, "进程列表中缺少当前写入实例".localized)
            }
            var pending: (process: WriterProcessIdentity, reason: String)?
            for process in processes {
                let presence: WriterPresence
                do { presence = try readPresence(processID: process.processID) }
                catch {
                    pending = (process, "该运行实例没有可验证的写入能力登记".localized)
                    break
                }
                guard presence.process == process else {
                    pending = (process, "登记与当前进程身份或启动时间不符".localized)
                    break
                }
                guard presence.dataDirectoryPath == dataDirectory.path else {
                    throw WriterAdmissionError.incompatibleWriter(process, "登记属于另一个数据目录".localized)
                }
                guard presence.capabilities.contains(Self.requiredCapability) else {
                    throw WriterAdmissionError.incompatibleWriter(process, "该运行实例不支持当前安全写入约定".localized)
                }
            }
            guard let pending else { return }
            let failure = WriterAdmissionError.incompatibleWriter(pending.process, pending.reason)
            guard registrationRetries < 40 else { throw failure }
            registrationRetries += 1

            // A launchd agent is visible to libproc before its Swift entry point
            // publishes its presence. Recheck the live identity and allow that
            // registration to settle; never infer capability from its file path.
            // An agent that exited during inspection is no longer a writer.
            guard try processSnapshot().contains(pending.process) else { continue }
            let started = Double(pending.process.startSeconds)
                + Double(pending.process.startMicroseconds) / 1_000_000
            let age = clock() - started
            guard age >= 0, age < 1 else { throw failure }
            waitForRegistration(min(0.025, 1 - age))
            // No write has been admitted. The next pass validates every live
            // instance again, including any PID reuse or newly started writer.
        }
    }

    func presenceURL(processID: Int32) -> URL {
        presenceDirectory.appendingPathComponent(String(processID) + ".plist")
    }

    private var presenceDirectory: URL { dataDirectory.appendingPathComponent(".writer-presence", isDirectory: true) }

    private func preparePresenceDirectory() throws {
        try FileManager.default.createDirectory(at: presenceDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(presenceDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else {
            throw WriterAdmissionError.inspectionFailed(nil, "写入能力登记目录的身份无法确认".localized)
        }
    }

    private func readPresence(processID: Int32) throws -> WriterPresence {
        let url = presenceURL(processID: processID)
        let directory = open(presenceDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { _ = close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= 65_536 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                offset += count
            }
        }
        return try PropertyListDecoder().decode(WriterPresence.self, from: Data(bytes))
    }

    static func currentProcessIdentity() throws -> WriterProcessIdentity {
        try identity(processID: getpid())
    }

    /// libproc also sees an executable launched directly as --mount-agent; a
    /// list of GUI applications alone would miss that writer. Bundle identity
    /// is used only to recognize candidates, never to infer their capability.
    static func runningAppPortsProcesses(processIDs: [Int32]? = nil,
        inspect: ((Int32) -> (proc_bsdinfo?, String?))? = nil) throws -> [WriterProcessIdentity] {
        let pids = try processIDs ?? currentUserProcessIDs()
        var result: [WriterProcessIdentity] = []
        for pid in pids {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let infoResult: Int32
            let path: String?
            if let inspect {
                let observed = inspect(pid)
                if let value = observed.0 { info = value; infoResult = size } else { infoResult = 0 }
                path = observed.1
            } else {
                infoResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
                path = executablePath(processID: pid)
            }
            if infoResult != size, processHasExited(pid) { continue }
            let name = withUnsafeBytes(of: info.pbi_name) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let namedAppPorts = name.caseInsensitiveCompare("AppPorts") == .orderedSame
            let relevant = pid == getpid() || namedAppPorts || path.map(isAppPortsExecutable) == true
            // Unrelated processes can exit or become unreadable between the
            // UID list and libproc calls. Only identified AppPorts candidates
            // participate in writer admission; unknown system activity must
            // not abort a transfer or prevent its journal from being saved.
            guard relevant else { continue }
            guard infoResult == size, let path else {
                if processHasExited(pid) { continue }
                throw WriterAdmissionError.inspectionFailed(pid, "运行实例的启动时间或可执行文件路径暂不可读".localized)
            }
            // Detect a PID disappearing/reappearing while it is inspected.
            let observed = makeIdentity(processID: pid, info: info, path: path)
            do {
                guard try identity(processID: pid) == observed else {
                    throw WriterAdmissionError.inspectionFailed(pid, "检查期间进程身份发生变化".localized)
                }
            } catch {
                if processHasExited(pid) { continue }
                throw error
            }
            result.append(observed)
        }
        return result.sorted { $0.processID < $1.processID }
    }

    private static func currentUserProcessIDs() throws -> [Int32] {
        let stride = MemoryLayout<Int32>.stride
        var capacity = max(128, Int(proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)) / stride + 64)
        for _ in 0..<4 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let byteCount = buffer.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
            }
            guard byteCount > 0 else {
                throw WriterAdmissionError.inspectionFailed(nil, "无法列出当前用户的运行进程".localized)
            }
            let count = Int(byteCount) / stride
            if count < capacity { return Array(Set(buffer.prefix(count).filter { $0 > 0 })).sorted() }
            capacity *= 2
        }
        throw WriterAdmissionError.inspectionFailed(nil, "运行进程列表持续变化，无法完成兼容检查".localized)
    }

    private static func identity(processID: Int32) throws -> WriterProcessIdentity {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              let path = executablePath(processID: processID) else {
            throw WriterAdmissionError.inspectionFailed(processID, "无法读取内核进程身份".localized)
        }
        return makeIdentity(processID: processID, info: info, path: path)
    }

    private static func makeIdentity(processID: Int32, info: proc_bsdinfo, path: String) -> WriterProcessIdentity {
        WriterProcessIdentity(processID: processID, userID: info.pbi_uid,
                              startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
                              executablePath: path)
    }

    private static func executablePath(processID: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro not imported by Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(processID, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }

    private static func isAppPortsExecutable(_ path: String) -> Bool {
        let executable = URL(fileURLWithPath: path)
        if executable.lastPathComponent.caseInsensitiveCompare("AppPorts") == .orderedSame { return true }
        var ancestor = executable.deletingLastPathComponent()
        while ancestor.path != "/" {
            if ancestor.pathExtension.lowercased() == "app" {
                return Bundle(url: ancestor)?.bundleIdentifier == "com.shimoko.AppPorts"
            }
            ancestor.deleteLastPathComponent()
        }
        return false
    }

    private static func processHasExited(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }
    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
