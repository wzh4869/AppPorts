import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

final class AppSettingsRenderTests: XCTestCase {
    private var originalLanguage = "system"
    private var originalLanguagePreference: Any?

    override func setUp() {
        super.setUp()
        originalLanguage = LanguageManager.shared.language
        originalLanguagePreference = UserDefaults.standard.object(forKey: "selectedLanguage")
    }

    override func tearDown() {
        LanguageManager.shared.language = originalLanguage
        if let originalLanguagePreference {
            UserDefaults.standard.set(originalLanguagePreference, forKey: "selectedLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        }
        super.tearDown()
    }

    @MainActor
    func testUpdateBadgesRespectScannedMigrationPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsPolicyRows-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = ["com.shimoko.AppPorts", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                   "io.github.clash-verge-rev.clash-verge-rev", "example.ordinary"]
        for id in ids {
            let contents = root.appendingPathComponent(id + ".app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks/Sparkle.framework"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let scanner = AppScanner(backupDirectoryURL: root.appendingPathComponent("Signatures"), adHocProbe: { _ in false })
        let apps = await scanner.scanLocalApps(at: root, runningAppURLs: [])
        XCTAssertEqual(apps.count, ids.count)
        XCTAssertEqual(Set(apps.filter(\.showsAppData).map(\.name)), Set(ids.dropFirst().map { $0 + ".app" }))
        for app in apps {
            for guardian in [UpdateRecommendationContext.Guardian.ready, .disabled, .unavailable] {
                let context = UpdateRecommendationContext(guardian: guardian)
                let view = NSHostingView(rootView: StatusBadge(app: app).environment(\.updateRecommendation, context))
                switch app.name {
                case "com.shimoko.AppPorts.app":
                    XCTAssertEqual(app.updateRoute.availability(in: context).badgeTitle, "自有")
                    XCTAssertGreaterThan(view.fittingSize.height, 0)
                case "example.ordinary.app":
                    XCTAssertEqual(app.updateRoute, .sparkle)
                    XCTAssertGreaterThan(view.fittingSize.height, 0)
                default:
                    XCTAssertEqual(app.bodyMigrationPolicy, .requiresConfirmation)
                    XCTAssertEqual(view.fittingSize.height, 0, app.name)
                    var running = app
                    running.isRunning = true
                    XCTAssertGreaterThan(NSHostingView(rootView: StatusBadge(app: running)).fittingSize.height, 0)
                }
            }
        }
    }

    @MainActor
    func testUpdateBadgeReservesItsRowHeightBeforeDiscovery() {
        let name = "Adobe Premiere Pro 2026.app"
        let url = URL(fileURLWithPath: "/Applications/" + name)
        let local = AppItem(name: name, path: url, status: AppStatus.local, updateRoute: .independent, bundleIsLocked: false)
        var linked = local
        linked.status = AppStatus.linked
        var running = linked
        running.isRunning = true
        var folder = local
        folder.isFolder = true
        let apps = [local, linked, running, folder]
        for language in ["zh-Hans", "en"] {
            LanguageManager.shared.language = language
            for app in apps {
                let cached = AppListCacheStore.Row(app, context: .init(guardian: .ready)).preview(size: nil, pane: .local)
                for width: CGFloat in [320, 380, 500] {
                    func height(_ item: AppItem, showsStatus: Bool) -> CGFloat {
                        let row = AppRowView(app: item, nameLineLimit: width < 420 ? 2 : 1,
                            showsStatus: showsStatus, showDeleteLinkButton: true,
                            onDeleteLink: { _ in }, onResign: nil, onRestoreSignature: nil)
                            .environment(\.updateRecommendation, .init(guardian: .ready))
                            .frame(width: width)
                        return NSHostingView(rootView: row).fittingSize.height
                    }
                    let pending = height(cached, showsStatus: false)
                    let confirmed = height(app, showsStatus: true)
                    XCTAssertEqual(pending, confirmed, accuracy: 0.01,
                                   "\(language), \(app.status), running \(app.isRunning), width \(width)")
                }
            }
        }
    }

    @MainActor
    func testFirstFrameUsesTheSameBadgeColorsAsInteractiveRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = AppItem(name: "Reader.app", path: URL(fileURLWithPath: "/Applications/Reader.app"),
            status: AppStatus.linked, isRunning: true, signatureReplaced: true, updateRoute: .independent, bundleIsLocked: false)
        let ready = UpdateRecommendationContext(guardian: .ready)
        let cached = AppListCacheStore.Row(live, context: ready).preview(size: nil, pane: .local)
        XCTAssertEqual(AppBadgeLayout(previewing: cached, context: .init(guardian: .unavailable)),
                       AppBadgeLayout(app: live, context: ready))
        XCTAssertNil(cached.bundleIsLocked)
        XCTAssertFalse(cached.isRunning || cached.signatureReplaced)

        for scheme in [ColorScheme.light, .dark] {
            var strengths: [CGFloat] = []
            for (stage, item) in [("cached", cached), ("discovered", live), ("interactive", live)] {
                let file = root.appendingPathComponent("\(scheme)-\(stage).png")
                let badges = StatusBadge(app: item, showsCachedBadges: stage == "cached")
                    .disabled(stage != "interactive")
                    .environment(\.colorScheme, scheme)
                    .environment(\.updateRecommendation, ready)
                    .frame(width: 440, height: 36, alignment: .leading)
                    .background(scheme == .light ? Color.white : .black)
                try await render(badges, size: NSSize(width: 440, height: 36), destination: file)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
                // The blue update badge is first. Its foreground must keep its normal contrast in all three phases.
                var strongestBlue: CGFloat = 0
                for x in 0..<min(100, bitmap.pixelsWide) {
                    for y in 0..<bitmap.pixelsHigh {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                            strongestBlue = max(strongestBlue, color.blueComponent - color.redComponent)
                        }
                    }
                }
                strengths.append(strongestBlue)
            }
            XCTAssertGreaterThan(strengths[2], 0.25) // Exclude a blank or background-only reference.
            XCTAssertEqual(strengths[0], strengths[2], accuracy: 0.04)
            XCTAssertEqual(strengths[1], strengths[2], accuracy: 0.04)
        }
    }

    @MainActor
    func testLocalFolderWithoutStatusHasNoBadge() {
        var folder = AppItem(name: "Utilities", path: URL(fileURLWithPath: "/Applications/Utilities"), status: AppStatus.local)
        folder.isFolder = true
        let badges = NSHostingView(rootView: StatusBadge(app: folder))
        XCTAssertEqual(badges.fittingSize.height, 0)
    }

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
        for code in ["zh-Hans", "en"] {
            LanguageManager.shared.language = code
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for locked in [false, true] {
                    for url in apps { XCTAssertEqual(chflags(url.path, locked ? UInt32(UF_IMMUTABLE) : 0), 0) }
                    let scanned = await scanner.scanLocalApps(at: root.appendingPathComponent("External"), runningAppURLs: [])
                    XCTAssertEqual(scanned.count, 3)
                    try await render(VStack(alignment: .leading, spacing: 0) {
                        ForEach(scanned) { original in
                            var app = original
                            app.status = AppStatus.linked
                            return Self.listRow(app, local: false)
                        }
                    }.environment(\.locale, Locale(identifier: code)).environment(\.colorScheme, dark ? .dark : .light),
                        size: NSSize(width: 480, height: 180),
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
        app.updateRoute = .shipIt
        app.bundleIsLocked = false
        app.size = "912 kB"
        var migrated = app
        migrated.status = AppStatus.linked
        migrated.needsLock = true
        migrated.isRunning = true
        for code in ["zh-Hans", "en", "fr"] {
            LanguageManager.shared.language = code
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let scheme: ColorScheme = dark ? .dark : .light
                let suffix = "\(code)-\(dark ? "dark" : "light")"
                let selection = try XCTUnwrap(ContentView.UpdateProtectionSelection(apps: [app], service: service) { _ in })
                let request = ContentView.updateProtectionRequest(for: selection, context: .init(guardian: .ready))
                try await render(WarningSheet(request).environment(\.locale, Locale(identifier: code))
                    .environment(\.colorScheme, scheme).environment(\.controlActiveState, .key),
                    size: NSSize(width: 520, height: 380), destination: output.appendingPathComponent("update-choice-\(suffix).png"),
                    activateWindow: true)
                try await render(HStack(alignment: .top, spacing: 0) {
                    ForEach([true, false], id: \.self) { local in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach([UpdateRecommendationContext.Guardian.ready, .disabled], id: \.self) { guardian in
                                Self.listRow(local ? app : migrated, local: local)
                                    .environment(\.updateRecommendation, .init(guardian: guardian))
                            }
                        }
                        if local { Divider() }
                    }
                }.environment(\.locale, Locale(identifier: code)).environment(\.colorScheme, scheme),
                    size: NSSize(width: 800, height: 158), destination: output.appendingPathComponent("update-badges-\(suffix).png"))
                try await render(VStack(alignment: .leading, spacing: 0) {
                    ForEach([UpdateRecommendationContext.Guardian.unavailable, .ready, .disabled], id: \.self) { guardian in
                        Self.listRow(migrated, local: true)
                            .environment(\.updateRecommendation, .init(guardian: guardian))
                    }
                }.environment(\.locale, Locale(identifier: code)).environment(\.colorScheme, scheme),
                    size: NSSize(width: 480, height: 192), destination: output.appendingPathComponent("guardian-badges-\(suffix).png"))
            }
        }
    }

    @MainActor
    private static func listRow(_ app: AppItem, local: Bool) -> some View {
        AppRowView(app: app, showDeleteLinkButton: local, onDeleteLink: { _ in },
                   onResign: nil, onRestoreSignature: nil)
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
