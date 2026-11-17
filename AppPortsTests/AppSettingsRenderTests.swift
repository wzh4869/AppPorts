import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

final class AppSettingsRenderTests: XCTestCase {
    @MainActor
    func testOrdinaryMigratedBadgesAndExistingLocks() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/Volumes/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT on an external volume for lock badge review")
        }
        let output = URL(fileURLWithPath: path)
        let root = output.appendingPathComponent("BadgeFixtures-" + UUID().uuidString)
        let scanner = AppScanner(backupDirectoryURL: root.appendingPathComponent("Signatures"), adHocProbe: { _ in false })
        let language = LanguageManager.shared.language
        let appearance = NSApp.appearance
        var apps: [URL] = []
        defer {
            for app in apps { _ = chflags(app.path, 0) }
            try? FileManager.default.removeItem(at: root)
            LanguageManager.shared.language = language
            NSApp.appearance = appearance
        }
        for (name, identifier) in [("NeteaseMusic", "com.netease.163music"), ("WorkBuddy", "com.tencent.workbuddy.mac"),
                                   ("DeepSeek Harness", "example.shipit")] {
            let app = root.appendingPathComponent("External/\(name).app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/Sparkle.framework"),
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            apps.append(app)
        }
        let scanned = await scanner.scanLocalApps(at: root.appendingPathComponent("External"), runningAppURLs: [])
        XCTAssertEqual(scanned.count, 3)
        for code in ["zh-Hans", "en"] {
            LanguageManager.shared.language = code
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for locked in [false, true] {
                    for url in apps { XCTAssertEqual(chflags(url.path, locked ? UInt32(UF_IMMUTABLE) : 0), 0) }
                    try await render(VStack(alignment: .leading, spacing: 16) {
                        ForEach(scanned) { original in
                            var app = original
                            app.status = AppStatus.linked
                            return HStack {
                                Text(app.displayName).frame(width: 160, alignment: .leading)
                                StatusBadge(app: app)
                                Spacer()
                            }
                        }
                    }.padding(16).environment(\.locale, Locale(identifier: code)).environment(\.colorScheme, dark ? .dark : .light),
                        size: NSSize(width: 480, height: 140),
                        destination: output.appendingPathComponent("migrated-badges-\(code)-\(dark ? "dark" : "light")-\(locked ? "locked" : "unlocked").png"))
                }
            }
        }
    }

    @MainActor
    func testUpdateMigrationChoiceAndFrameworkFreeBadges() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT for migration visual review")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsUpdateChoiceRender-" + UUID().uuidString)
        let source = root.appendingPathComponent("DeepSeek Harness.app")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/Frameworks/Squirrel.framework"),
                                                withIntermediateDirectories: true)
        let metadata: [String: Any] = ["CFBundleIdentifier": "example.render", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        let service = AppMigrationService(transferStore: AppTransferStore(directoryURL: root.appendingPathComponent("Journal")),
            signatureFactStore: SignatureFactStore(backupDirectoryURL: root.appendingPathComponent("Signatures")))
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = LanguageManager.shared.language
        let appearance = NSApp.appearance
        defer { try? FileManager.default.removeItem(at: root); LanguageManager.shared.language = language; NSApp.appearance = appearance }
        var app = AppItem(name: source.lastPathComponent, path: source, status: AppStatus.local)
        app.isSparkleApp = true
        app.isElectronApp = true
        for code in ["zh-Hans", "en", "fr"] {
            LanguageManager.shared.language = code
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let scheme: ColorScheme = dark ? .dark : .light
                let suffix = "\(code)-\(dark ? "dark" : "light")"
                let request = try XCTUnwrap(ContentView.updateProtectionRequest(for: [app], service: service) { _ in })
                try await render(WarningSheet(request).environment(\.locale, Locale(identifier: code))
                    .environment(\.colorScheme, scheme).environment(\.controlActiveState, .key),
                    size: NSSize(width: 520, height: 380), destination: output.appendingPathComponent("update-choice-\(suffix).png"),
                    activateWindow: true)
                try await render(HStack(spacing: 12) {
                    Text(app.displayName)
                    StatusBadge(app: app)
                    Spacer()
                }.padding(16).environment(\.locale, Locale(identifier: code)).environment(\.colorScheme, scheme),
                    size: NSSize(width: 520, height: 64), destination: output.appendingPathComponent("update-badges-\(suffix).png"))
            }
        }
    }

    @MainActor
    func testAppStoreConfiguredAndUnconfiguredSectionAndGuidance() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT for settings visual review")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "AppStoreSectionRender-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let language = LanguageManager.shared.language
        let appearance = NSApp.appearance
        defer { defaults.removePersistentDomain(forName: suite); LanguageManager.shared.language = language; NSApp.appearance = appearance }
        let volume = UUID()
        for code in ["zh-Hans", "en"] {
            LanguageManager.shared.language = code
            NSApp.appearance = NSAppearance(named: .aqua)
            for configured in [true, false] {
                let settings = AppStoreExternalInstallSettings(defaults: defaults, probe: .init(
                    preference: { configured ? .enabled(volumeUUID: volume, name: "Validation") : .disabled },
                    volumeUUID: { _ in volume }), isSupported: true)
                settings.refresh(for: URL(fileURLWithPath: "/Volumes/Validation/appdisks"))
                for width: CGFloat in [420, 620] {
                    try await render(AppStoreExternalInstallSection(settings: settings)
                        .environment(\.locale, Locale(identifier: code)).environment(\.colorScheme, .light),
                        size: NSSize(width: width, height: 320),
                        destination: output.appendingPathComponent("appstore-\(code)-\(configured ? "configured" : "unconfigured")-\(Int(width)).png"))
                }
                if !configured {
                    let request = settings.makeGuidanceRequest(onOpenAppStore: {}, onCheck: {})
                    try await render(WarningSheet(request).environment(\.locale, Locale(identifier: code)).environment(\.colorScheme, .light),
                        size: NSSize(width: 520, height: 420),
                        destination: output.appendingPathComponent("appstore-\(code)-guidance.png"))
                }
            }
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, size: NSSize, destination: URL, activateWindow: Bool = false) async throws {
        let host = NSHostingView(rootView: view.background(AppSettingsStyle.background))
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: activateWindow ? [.titled] : [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSApp.appearance
        window.setFrameOrigin(NSPoint(x: -10_000, y: 0))
        if activateWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        defer { window.close() }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        try png.write(to: destination)
    }

    @MainActor
    func testEmbeddedSettingsInChineseEnglishAndDeferredLanguage() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT for settings visual review")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "AppSettingsRender-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = LanguageManager.shared.language
        let appearance = NSApp.appearance
        defer { LanguageManager.shared.language = language; NSApp.appearance = appearance }
        let sync = AppLibraryAgentSync(synchronize: {})
        let volume = UUID()
        defaults.set("/Volumes/Validation/appdisks", forKey: LaunchReadinessChecker.externalDrivePathKey)
        for code in ["zh-Hans", "en", "fr"] {
            LanguageManager.shared.language = code
            for scheme in [ColorScheme.light, .dark] {
                NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                for width: CGFloat in [660, 940] {
                    for needsAttention in [false, true] {
                        let externalPath = needsAttention
                            ? "/Volumes/Validation External Storage With a Longer Name/appdisks"
                            : "/Volumes/Validation/appdisks"
                        defaults.set(externalPath, forKey: LaunchReadinessChecker.externalDrivePathKey)
                        let readiness = ReadinessCheckModel(checker: LaunchReadinessChecker(probe: .init(
                            fullDiskAccessState: { needsAttention ? .denied : .granted },
                            appManagementState: { needsAttention ? .unknown : .granted },
                            externalDrivePath: { externalPath },
                            externalDriveState: { _ in needsAttention ? .notAPFS(filesystem: "exFAT") : .apfs })), didCheck: { _ in })
                        let appStore = AppStoreExternalInstallSettings(defaults: defaults, probe: .init(
                            preference: { needsAttention ? .disabled : .enabled(volumeUUID: volume, name: "Validation") },
                            volumeUUID: { _ in volume }), isSupported: true)
                        try await render(AppStoreSettingsView(agentSync: sync, readiness: readiness, appStoreInstall: appStore)
                            .defaultAppStorage(defaults)
                            .environment(\.locale, Locale(identifier: code)).environment(\.colorScheme, scheme),
                            size: NSSize(width: width, height: 720),
                            destination: output.appendingPathComponent("settings-\(code)-\(scheme == .light ? "light" : "dark")-\(Int(width))\(needsAttention ? "-attention" : "").png"))
                    }
                }
            }
        }
    }
}
