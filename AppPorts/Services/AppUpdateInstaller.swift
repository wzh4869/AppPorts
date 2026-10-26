import AppKit
import Foundation

/// The helper only replaces the application after the running process has exited.
/// A previous copy remains available until the new application acknowledges launch.
enum AppUpdateInstaller {
    private struct Receipt: Codable {
        let destination: String
        let version: String
    }

    static func launch(_ update: PreparedAppUpdate) throws -> Process {
        guard try GitHubUpdatePackage.validateDestination(update.destination) == update.originalIdentity,
              try GitHubUpdatePackage.identity(at: update.stagedApplication) == update.stagedIdentity else {
            throw AppUpdateError.changed
        }
        let otherInstances = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.standardizedFileURL == update.destination.standardizedFileURL
        }
        guard otherInstances.isEmpty else { throw AppUpdateError.changed }
        let receipt = Receipt(destination: update.destination.path, version: update.version)
        try PropertyListEncoder().encode(receipt).write(to: update.workspace.appendingPathComponent("receipt.plist"), options: .atomic)
        let scriptURL = update.workspace.appendingPathComponent("install.sh")
        try script(for: update, parentPID: ProcessInfo.processInfo.processIdentifier)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let log = update.workspace.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.currentDirectoryURL = update.workspace
        try process.run()
        return process
    }

    static func acknowledgeLaunch(bundle: Bundle = .main, arguments: [String] = CommandLine.arguments) {
        guard let flag = arguments.firstIndex(of: "--appports-update-token"), flag + 1 < arguments.count,
              let token = UUID(uuidString: arguments[flag + 1]),
              bundle.bundleIdentifier == "com.shimoko.AppPorts" else { return }
        let destination = bundle.bundleURL.standardizedFileURL
        let workspace = destination.deletingLastPathComponent()
            .appendingPathComponent(".AppPorts-update-" + token.uuidString)
        do {
            guard workspace.resolvingSymlinksInPath().path == workspace.path else { return }
            let receipt = try PropertyListDecoder().decode(Receipt.self,
                from: Data(contentsOf: workspace.appendingPathComponent("receipt.plist")))
            guard receipt.destination == destination.path,
                  receipt.version == bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
            try Data().write(to: workspace.appendingPathComponent("launched"), options: .atomic)
        } catch {
            AppLogger.shared.logError("更新启动确认失败，旧版本备份已保留", error: error)
        }
    }

    static func script(for update: PreparedAppUpdate, parentPID: Int32,
                       relaunchCommand: [String]? = nil, recoveryCommand: [String]? = nil,
                       failureCommand: [String]? = nil, waitAttempts: Int = 120) -> String {
        let token = String(update.workspace.lastPathComponent.dropFirst(".AppPorts-update-".count))
        let launch = relaunchCommand ?? ["/usr/bin/open", "-n", update.destination.path,
                                         "--args", "--appports-update-token", token]
        let failure = "自动更新未完成，旧版本备份已保留。请重新打开 AppPorts，或前往发布页手动更新。".localized
        let report = failureCommand ?? ["/usr/bin/osascript", "-e", "on run argv", "-e",
                                       "display alert \"AppPorts\" message (item 1 of argv)", "-e", "end run", failure]
        let recover = recoveryCommand ?? ["/usr/bin/open", "-n", update.destination.path]
        return """
        #!/bin/sh
        set -eu
        umask 077
        target=\(quote(update.destination.path))
        work=\(quote(update.workspace.path))
        staged="$work/AppPorts.app"
        backup="$work/Previous.app"
        fail() {
            \(report.map(quote).joined(separator: " ")) || true
            exit 1
        }
        count=0
        while /bin/kill -0 \(parentPID) 2>/dev/null; do
            count=$((count + 1))
            [ "$count" -le \(waitAttempts) ] || exit 1
            /bin/sleep 1
        done
        [ ! -L "$target" ] && [ ! -L "$staged" ] && [ ! -e "$backup" ] || fail
        [ "$(/usr/bin/stat -f '%d:%i' "$target")" = \(quote(update.originalIdentity)) ] || fail
        [ "$(/usr/bin/stat -f '%d:%i' "$staged")" = \(quote(update.stagedIdentity)) ] || fail
        /bin/mv "$target" "$backup" || fail
        if ! /bin/mv "$staged" "$target"; then
            /bin/mv "$backup" "$target" || true
            \(recover.map(quote).joined(separator: " ")) || true
            fail
        fi
        if ! \(launch.map(quote).joined(separator: " ")); then
            # Preserve the failed new copy as well as restoring the original.
            /bin/mv "$target" "$staged" && /bin/mv "$backup" "$target" || fail
            \(recover.map(quote).joined(separator: " ")) || true
            fail
        fi
        count=0
        while [ ! -f "$work/launched" ]; do
            count=$((count + 1))
            # A successful open request alone does not prove launch. Keep the backup on timeout.
            [ "$count" -le \(waitAttempts) ] || exit 0
            /bin/sleep 1
        done
        /bin/rm -rf "$work"
        """
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
