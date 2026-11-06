import Cocoa
import Carbon
import os

/// AppPorts Stub Portal Native Launcher
///
/// Replaces the bash launcher script in macOS Stub Portals.
/// Receives `kAEOpenDocuments` Apple Events and forwards them
/// to the real app on external storage.
///
/// Companion file at Contents/Resources/real_app_path.txt contains
/// the path to the real .app bundle.

/// This process uses the system's preferred languages. Its generated translations
/// come from the app catalog, without needing the AppPorts app to be running.
enum DiskMissingStrings {
    static var current: (message: String, button: String) {
        (PortalLocalizedStrings.text("外部存储未连接，请连接后重试。"),
         PortalLocalizedStrings.text("好"))
    }
}

final class AppDelegate: NSObject {
    private let logger = Logger(subsystem: "com.shimoko.AppPorts.StubLauncher", category: "launch")
    private var canTerminate = false
    private var receivedOpenRequest = false
    private var pendingRequests = 0
    private var failed = false
    private var finished = false
    private var storagePrepared = false
    private var preparingStorage = false
    private var waitingRequests: [[URL]] = []
    private var preparationLease: ApplicationLaunchGate.Lease?
    private let startedAt = ProcessInfo.processInfo.systemUptime

    func readRealAppPath() -> String {
        guard let resURL = Bundle.main.resourceURL else { return "" }
        let pathFile = resURL.appendingPathComponent("real_app_path.txt")
        return (try? String(contentsOf: pathFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func start() {
        let events = NSAppleEventManager.shared()
        for eventID in [kAEOpenApplication, kAEReopenApplication] {
            events.setEventHandler(self, andSelector: #selector(handleLaunch(_:withReplyEvent:)),
                                   forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(eventID))
        }
        events.setEventHandler(self, andSelector: #selector(handleDocuments(_:withReplyEvent:)),
                               forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        events.setEventHandler(self, andSelector: #selector(handleURL(_:withReplyEvent:)),
                               forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        // Direct executable launches do not deliver an initial Apple Event.
        // Run the fallback on the event loop, without an artificial delay.
        DispatchQueue.main.async {
            self.canTerminate = true
            if !self.receivedOpenRequest { self.openRealApplication(urls: []) }
            self.terminateIfFinished()
        }
    }

    func run() {
        // Dispatch Apple Events without NSApplication.run(), which also starts
        // AppKit's document/window restoration machinery for the portal.
        while !finished {
            autoreleasepool {
                var event: EventRef?
                // Carbon's -1 timeout means wait until an event or completion;
                // the equivalent C macro is not imported by current Swift SDKs.
                let status = ReceiveNextEvent(0, nil, EventTimeout(-1.0), true, &event)
                guard status == noErr, let event else {
                    if !finished { logger.error("Event loop stopped: \(status)") }
                    finished = true
                    return
                }
                defer { ReleaseEvent(event) }
                if GetEventClass(event) == OSType(kEventClassAppleEvent) {
                    _ = AEProcessEvent(event)
                } else {
                    _ = SendEventToEventTarget(event, GetEventDispatcherTarget())
                }
            }
        }
    }

    @objc private func handleLaunch(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        // The bootstrap and initial/reopen events must not launch the target twice.
        if !receivedOpenRequest && !failed { openRealApplication(urls: []) }
    }

    @objc private func handleDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let items = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)), items.numberOfItems > 0 else {
            reject(reply)
            return
        }
        var urls: [URL] = []
        for index in 1...items.numberOfItems {
            guard let url = items.atIndex(index)?.fileURLValue else {
                reject(reply)
                return
            }
            urls.append(url)
        }
        openRealApplication(urls: urls)
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value) else {
            reject(reply)
            return
        }
        openRealApplication(urls: [url])
    }

    private func reject(_ reply: NSAppleEventDescriptor) {
        if reply.descriptorType != DescType(typeNull) {
            reply.setParam(NSAppleEventDescriptor(int32: Int32(errAECoercionFail)), forKeyword: AEKeyword(keyErrorNumber))
        }
    }

    private func openRealApplication(urls: [URL]) {
        receivedOpenRequest = true
        guard storagePrepared else {
            prepareStorage(urls: urls)
            return
        }
        logger.notice("Forwarding launch; URLs: \(urls.count), elapsed ms: \(Int((ProcessInfo.processInfo.systemUptime - self.startedAt) * 1000))")
        let path = readRealAppPath()
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            failed = true
            logger.error("Target missing: \(path, privacy: .public)")
            showExternalDiskMissing()
            terminateIfFinished()
            return
        }
        let launchLease: ApplicationLaunchGate.Lease
        do {
            guard let identifier = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier, !identifier.isEmpty,
                  let expected = Bundle.main.object(forInfoDictionaryKey: "AppPortsTargetBundleIdentifier") as? String,
                  identifier == expected else { throw ApplicationLaunchGate.Failure.inspection }
            launchLease = try ApplicationLaunchGate.acquire(bundleIdentifier: identifier, migrating: false)
        } catch {
            failed = true
            logger.error("Launch protection rejected forwarding: \(String(describing: error), privacy: .public)")
            showDialog(message: ApplicationLaunchGate.message(busy: (error as? ApplicationLaunchGate.Failure) == .busy),
                       button: PortalLocalizedStrings.text("好"))
            terminateIfFinished()
            return
        }
        pendingRequests += 1
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion: (NSRunningApplication?, Error?) -> Void = { application, error in
            DispatchQueue.main.async {
                defer { withExtendedLifetime(launchLease) {} }
                self.pendingRequests -= 1
                let succeeded = application != nil && error == nil
                self.logger.notice("Launch completed; success: \(succeeded), elapsed ms: \(Int((ProcessInfo.processInfo.systemUptime - self.startedAt) * 1000))")
                if !succeeded && !self.failed {
                    self.failed = true
                    self.logger.error("Launch failed: \(String(describing: error), privacy: .public)")
                    let message = PortalLocalizedStrings.text("无法打开应用") + "\n\n" + path + "\n\n"
                        + (error?.localizedDescription ?? PortalLocalizedStrings.text("系统未能完成启动，请重试。"))
                    self.showDialog(message: message, button: PortalLocalizedStrings.text("好"))
                }
                self.terminateIfFinished()
            }
        }
        let applicationURL = URL(fileURLWithPath: path)
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration,
                                               completionHandler: completion)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: applicationURL,
                                    configuration: configuration, completionHandler: completion)
        }
    }

    private func prepareStorage(urls: [URL]) {
        guard !failed else { return }
        waitingRequests.append(urls)
        guard !preparingStorage else { return }
        preparingStorage = true
        // Old portals retain their previous behavior until refreshed by AppPorts.
        guard let helper = Bundle.main.object(forInfoDictionaryKey: "AppPortsLaunchHelperPath") as? String else {
            finishPreparation(succeeded: true)
            return
        }
        do {
            guard let identifier = Bundle.main.object(forInfoDictionaryKey: "AppPortsTargetBundleIdentifier") as? String,
                  !identifier.isEmpty else { throw ApplicationLaunchGate.Failure.inspection }
            // Hold protection before attaching storage, through final launch completion.
            preparationLease = try ApplicationLaunchGate.acquire(bundleIdentifier: identifier, migrating: false)
        } catch {
            failed = true
            waitingRequests.removeAll()
            showDialog(message: ApplicationLaunchGate.message(busy: (error as? ApplicationLaunchGate.Failure) == .busy),
                       button: PortalLocalizedStrings.text("好"))
            terminateIfFinished()
            return
        }
        pendingRequests += 1
        let portalPath = Bundle.main.bundleURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["--prepare-image-launch", portalPath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let succeeded: Bool
            do {
                try process.run()
                process.waitUntilExit()
                // 2 means the request uses no managed image; keep physical-disk behavior.
                succeeded = process.terminationStatus == 0 || process.terminationStatus == 2
            } catch {
                self.logger.error("Image launch helper unavailable: \(String(describing: error), privacy: .public)")
                succeeded = false
            }
            DispatchQueue.main.async {
                self.pendingRequests -= 1
                self.finishPreparation(succeeded: succeeded)
            }
        }
    }

    private func finishPreparation(succeeded: Bool) {
        preparingStorage = false
        let requests = waitingRequests
        waitingRequests.removeAll()
        guard succeeded else {
            failed = true
            showExternalDiskMissing()
            terminateIfFinished()
            return
        }
        storagePrepared = true
        for urls in requests where !failed { openRealApplication(urls: urls) }
        terminateIfFinished()
    }

    private func terminateIfFinished() {
        // Keep the event loop alive until all forwarded requests complete.
        if canTerminate && pendingRequests == 0 {
            finished = true
            QuitEventLoop(GetMainEventLoop())
        }
    }

    /// Wraps a string as an AppleScript double-quoted literal, escaping `\` and `"`.
    private func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    func showExternalDiskMissing() {
        let strings = DiskMissingStrings.current
        showDialog(message: strings.message, button: strings.button)
    }

    private func showDialog(message: String, button: String) {
        let script = "display dialog \(appleScriptLiteral(message)) "
            + "buttons {\(appleScriptLiteral(button))} default button 1 with icon caution"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
        proc.waitUntilExit()
    }
}

// A portal handles only Launch Services requests; the real application owns
// all AppKit startup, documents, restoration, menus and windows.
let launcher = AppDelegate()
if CommandLine.arguments.dropFirst().contains("--storage-missing") {
    launcher.showExternalDiskMissing()
} else {
    launcher.start()
    launcher.run()
}
