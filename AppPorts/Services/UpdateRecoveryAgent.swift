import AppKit
import Darwin
import Foundation

enum UpdateRecoveryAgent {
    /// This entry precedes SwiftUI startup and keeps only the event worker alive.
    static func runAndExit() -> Never {
        let dataDirectory: URL
        #if DEBUG
        if let fixture = ProcessInfo.processInfo.environment["APPPORTS_TEST_UPDATE_AGENT_ROOT"] {
            dataDirectory = URL(fileURLWithPath: fixture, isDirectory: true)
        } else {
            dataDirectory = WriterAdmission.defaultDataDirectory
        }
        #else
        dataDirectory = WriterAdmission.defaultDataDirectory
        #endif
        guard let defaults = dataDirectory == WriterAdmission.defaultDataDirectory ? UserDefaults.standard
            : UserDefaults(suiteName: "org.appports.update-agent-fixture." + dataDirectory.lastPathComponent) else { exit(1) }
        guard BackgroundAgentPreferences.updateGuardianEnabled(defaults: defaults) else { exit(0) }
        do {
            if dataDirectory == WriterAdmission.defaultDataDirectory { try WriterAdmission.registerCurrentWriter() }
            else { try WriterAdmission(dataDirectory: dataDirectory).registerCurrentProcess() }
        } catch {
            AppLogger.shared.logError("更新守护未取得写入资格", error: error)
            AppLogger.shared.flush()
            exit(1)
        }
        // Creating NSApplication registers this worker as AppPorts itself and
        // prevents Launch Services from opening the GUI after the GUI quits.
        // The recovery worker only needs the run loop and workspace notifications.
        let records = AppSearchRecordStore(fileURL: dataDirectory.appendingPathComponent("app-search-records.json"))
        let directory = dataDirectory.appendingPathComponent("shipit-recovery")
        let caches = dataDirectory == WriterAdmission.defaultDataDirectory
            ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            : dataDirectory.appendingPathComponent("Caches")
        let recovery = ShipItUpdateRecovery(records: records, caches: caches, directory: directory,
            launchLocks: dataDirectory == WriterAdmission.defaultDataDirectory
                ? ApplicationLaunchGate.defaultDirectory : dataDirectory.appendingPathComponent("launch-locks"),
            operationLock: OperationLock(fileURL: dataDirectory.appendingPathComponent("operation.lock")))
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let initialExecutablePath = (try? WriterAdmission.currentProcessIdentity().executablePath)
            ?? (Bundle.main.executableURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AppPorts")).standardizedFileURL.path
        let readiness: GuardianReadiness
        do { readiness = try GuardianReadiness(executable: URL(fileURLWithPath: initialExecutablePath)) }
        catch {
            AppLogger.shared.logError("无法确认更新守护启动时的进程身份", error: error)
            AppLogger.shared.flush()
            exit(1)
        }
        Task { @MainActor in
            var didCheck: (() -> Void)?
            #if DEBUG
            if dataDirectory != WriterAdmission.defaultDataDirectory {
                var checks = 0
                didCheck = {
                    checks += 1
                    let state = ["checks": checks, "windows": NSApp?.windows.count ?? 0,
                                 "activationPolicy": NSApp?.activationPolicy().rawValue ?? -1]
                    try? JSONSerialization.data(withJSONObject: state).write(
                        to: dataDirectory.appendingPathComponent("agent-observation.json"), options: .atomic)
                }
            }
            #endif
            let monitor = ShipItRecoveryMonitor(recovery: recovery,
                didCheck: didCheck,
                observedStore: ShipItObservedTaskStore(directory: directory),
                didStartListening: { try readiness.publish(in: dataDirectory) })
            var shuttingDown = false
            var executableMonitor: ExecutableReplacementMonitor?
            let shutdown: @MainActor (String, Bool) -> Void = { message, disabledByUser in
                guard !shuttingDown else { return }
                shuttingDown = true
                executableMonitor?.stop()
                Task { @MainActor in
                    await monitor.stop(disabledByUser: disabledByUser)
                    AppLogger.shared.log(message)
                    AppLogger.shared.flush()
                    exit(0)
                }
            }
            executableMonitor = ExecutableReplacementMonitor(executablePath: initialExecutablePath, queue: .main) {
                Task { @MainActor in
                    shutdown("检测到 AppPorts 应用包已移动或替换，旧版后台更新守护退出", false)
                }
            }
            termination.setEventHandler {
                Task { @MainActor in
                    // launchd uses SIGTERM both for disabling the setting and for replacing a worker.
                    defaults.synchronize()
                    shutdown("后台更新守护退出", !BackgroundAgentPreferences.updateGuardianEnabled(defaults: defaults))
                }
            }
            termination.resume()
            if let executableMonitor, !executableMonitor.isExecutableStillCurrent() {
                shutdown("检测到 AppPorts 应用包已移动或替换，旧版后台更新守护退出", false)
                return
            }
            monitor.start()
            AppLogger.shared.log("后台更新守护启动")
        }
        CFRunLoopRun()
        exit(0)
    }

    /// Watches both the running executable and its enclosing `.app` bundle via kqueue
    /// so a manual Finder replace or backup move triggers graceful `exit(0)` without polling.
    final class ExecutableReplacementMonitor {
        private let initialPath: String
        private let initialIdentity: DataPathIdentity
        private var sources: [DispatchSourceFileSystemObject] = []

        init?(executablePath: String, queue: DispatchQueue = .main, onReplaced: @escaping () -> Void) {
            let standardized = URL(fileURLWithPath: executablePath).standardizedFileURL.path
            guard let identity = try? DataPathIdentity.capture(URL(fileURLWithPath: standardized)) else { return nil }
            self.initialPath = standardized
            self.initialIdentity = identity

            var watchPaths = [standardized]
            if let bundlePath = Self.enclosingAppBundlePath(for: standardized) {
                watchPaths.append(bundlePath)
            }
            for path in watchPaths {
                let fd = open(path, O_EVTONLY | O_CLOEXEC)
                guard fd >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.delete, .rename, .revoke],
                    queue: queue
                )
                source.setEventHandler { [weak self] in
                    guard let self, !self.isExecutableStillCurrent() else { return }
                    onReplaced()
                }
                source.setCancelHandler {
                    _ = close(fd)
                }
                source.resume()
                sources.append(source)
            }
            guard !sources.isEmpty else { return nil }
        }

        func isExecutableStillCurrent() -> Bool {
            guard let currentIdentity = try? DataPathIdentity.capture(URL(fileURLWithPath: initialPath)),
                  currentIdentity.matchesFilesystemObject(initialIdentity) else { return false }
            guard let livePath = WriterAdmission.executablePath(processID: getpid()) else { return false }
            let liveCanonical = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath().path
            let initialCanonical = URL(fileURLWithPath: initialPath).standardizedFileURL.resolvingSymlinksInPath().path
            return liveCanonical == initialCanonical
        }

        func stop() {
            let active = sources
            sources.removeAll()
            active.forEach { $0.cancel() }
        }

        deinit { stop() }

        static func enclosingAppBundlePath(for executablePath: String) -> String? {
            var current = URL(fileURLWithPath: executablePath).standardizedFileURL.deletingLastPathComponent()
            while current.path != "/" {
                if current.pathExtension.lowercased() == "app" {
                    return current.path
                }
                current.deleteLastPathComponent()
            }
            return nil
        }
    }
}

// A launchd registration can outlive its worker. The snapshot only describes this process
// and the executable it started from. It grants no permission to install an update.
struct GuardianReadiness: Codable {
    let process: WriterProcessIdentity
    let executableIdentity: DataPathIdentity
    let build: String

    init(executable: URL) throws {
        process = try WriterAdmission.currentProcessIdentity()
        executableIdentity = try DataPathIdentity.capture(executable)
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private static func file(in directory: URL) -> URL {
        directory.appendingPathComponent("update-guardian-ready.plist")
    }

    func publish(in directory: URL) throws {
        try PropertyListEncoder().encode(self).write(to: Self.file(in: directory), options: .atomic)
    }

    static func matches(pid: Int32, executable: URL, directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: file(in: directory)),
              let ready = try? PropertyListDecoder().decode(Self.self, from: data),
              ready.process.processID == pid, !ready.build.isEmpty,
              ready.build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              WriterAdmission.matchesRunningProcess(ready.process),
              WriterAdmission.isProcessCompliantWriter(pid: pid, expectedExecutablePath: executable.path, dataDirectory: directory),
              let installed = try? DataPathIdentity.capture(executable) else { return false }
        return installed.matchesFilesystemObject(ready.executableIdentity)
    }
}
