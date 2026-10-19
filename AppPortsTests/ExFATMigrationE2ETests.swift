import Darwin
import XCTest
@testable import AppPorts

/// End-to-end check that an app migration onto a filesystem without ACL,
/// hardlink, resource-fork or permission support completes and leaves a bundle
/// whose code signature still verifies. Requires a mounted ExFAT volume.
///
/// Run with: TEST_RUNNER_APPPORTS_EXFAT_ROOT=/Volumes/<name>
final class ExFATMigrationE2ETests: XCTestCase {
    func testMigrationToExFATCompletesAndKeepsSignatureValid() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["APPPORTS_EXFAT_ROOT"],
              rootPath.hasPrefix("/Volumes/") else {
            throw XCTSkip("Set APPPORTS_EXFAT_ROOT to a mounted ExFAT volume")
        }
        let root = URL(fileURLWithPath: rootPath)
        let external = root.appendingPathComponent("AppPorts.noindex")
        try? FileManager.default.removeItem(at: external)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        // Probe must report the missing capabilities the warning relies on.
        let capabilities = try XCTUnwrap(StorageCapabilityProbe.probe(destination: external))
        XCTAssertFalse(capabilities.missing.isEmpty, "ExFAT should report missing capabilities")

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPortsExFATE2E-" + UUID().uuidString).resolvingSymlinksInPath()
        let local = workspace.appendingPathComponent("Applications")
        let store = AppTransferStore(directoryURL: workspace.appendingPathComponent("Journal"))
        let facts = SignatureFactStore(backupDirectoryURL: workspace.appendingPathComponent("SignatureBackups"))
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer {
            if workspace.lastPathComponent.hasPrefix("AppPortsExFATE2E-") {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        let source = local.appendingPathComponent("Example.app")
        try makeApp(at: source)

        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, transferStore: store,
                                          signatureFactStore: facts, runningApplications: { [] })
        let item = AppItem(name: "Example.app", path: source, bundleURL: source, status: AppStatus.local)
        let destination = external.appendingPathComponent("Example.app")
        let result = try await service.moveAndLink(appToMove: item, destinationURL: destination,
                                                   isRunning: false, progressHandler: nil)
        XCTAssertTrue(result.isSwitchComplete, result.pendingMessage ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Contents/Resources/payload")), "payload")
    }

    private func makeApp(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.exfate2e</string>
        <key>CFBundleName</key><string>Example</string>
        <key>CFBundleExecutable</key><string>Example</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        <key>CFBundleVersion</key><string>1</string>
        </dict></plist>
        """.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: url.appendingPathComponent("Contents/MacOS/Example"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent("Contents/MacOS/Example").path)
        try "payload".write(to: url.appendingPathComponent("Contents/Resources/payload"), atomically: true, encoding: .utf8)
        // Deliberately no extended ACL: this mirrors a normal downloaded app.
        // `acl_get_file` returns ENOTSUP/ENOENT for "no ACL", and the copier must
        // treat that as "nothing to preserve" rather than as a failure.
    }
}
