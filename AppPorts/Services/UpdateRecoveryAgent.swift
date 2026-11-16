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
                observedStore: ShipItObservedTaskStore(directory: directory))
            termination.setEventHandler {
                Task { @MainActor in
                    await monitor.stop()
                    AppLogger.shared.log("后台更新守护退出")
                    exit(0)
                }
            }
            termination.resume()
            monitor.start()
            AppLogger.shared.log("后台更新守护启动")
        }
        CFRunLoopRun()
        exit(0)
    }
}
