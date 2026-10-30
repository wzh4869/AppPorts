import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

/// Opt-in visual evidence from production components and synthetic models only.
/// Run with TEST_RUNNER_APPPORTS_RENDER_UI_OUTPUT=/absolute/output/directory.
/// No DataDirsView, scanner or migration service is instantiated; preferences use isolated test suites.
final class MigrationSafetyRenderTests: XCTestCase {
    @MainActor
    func testRenderManualPauseStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to render manual pause states")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: "/AppPortsSyntheticHome/Library/Containers/com.example.pause/Data/Documents")
        let items = [DataDirStatus.mounted, DataDirStatus.pendingMount, DataDirStatus.volumeMissing].enumerated().map { index, status in
            var item = DataDirItem(name: "Pause example \(index + 1)", path: root.appendingPathComponent("Cache\(index)"),
                type: .containers, priority: .optional, description: "", status: status, autoMountPaused: true)
            item.requiresMountMigration = true
            item.size = "128 MB"
            return item
        }
        for scheme in [ColorScheme.light, .dark] {
            let view = AppDataDirectoryBrowser(groups: [DataDirGroup(type: .containers, items: items)],
                matchingItemIDs: Set(items.map(\.id)), isFiltering: false, showLockedStructure: false) { item in
                    self.actions(for: item)
                }
            try await render(view, size: NSSize(width: 680, height: 420),
                to: output.appendingPathComponent("manual-pause-\(scheme).png"), colorScheme: scheme)
        }
    }

    /// Exercise production sheets with synthetic records only; no migration is submitted.
    @MainActor
    func testRenderLocalizationSheets() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to inspect localized sheets")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizationSheets-\(UUID().uuidString)")
        let originalLanguage = LanguageManager.shared.language
        let originalLanguagePreference = UserDefaults.standard.object(forKey: "selectedLanguage")
        defer {
            LanguageManager.shared.language = originalLanguage
            if let originalLanguagePreference {
                UserDefaults.standard.set(originalLanguagePreference, forKey: "selectedLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedLanguage")
            }
            try? FileManager.default.removeItem(at: fixture)
        }
        for language in ["zh-Hans", "en", "de", "pl", "ar"] {
            LanguageManager.shared.language = language
            let locale = Locale(identifier: language)
            let direction: LayoutDirection = language == "ar" ? .rightToLeft : .leftToRight
            let history = MigrationTaskHistoryStore(fileURL: fixture.appendingPathComponent("\(language).json"))
            let job = MigrationJob(title: "正在迁移应用".localized, category: .apps,
                resources: MigrationResources(paths: []), startedAt: Date(timeIntervalSince1970: 1_792_712_096))
            job.status = .attention
            job.restoredFraction = 0.94
            job.restoredElapsed = 125
            job.message = "部分数据操作尚未完成，已保留副本。".localized
            history.save([MigrationTaskHistoryStore.Entry(job)])
            let center = MigrationTaskCenter(historyStore: history)
            let transfer = DataTransferRecord(mode: .symlink, direction: .migrate,
                appName: "Example Application", dataDirType: "Application Support",
                originalPath: "/Synthetic/Library/Application Support/Example Application",
                activePath: "/Volumes/Example Disk/Example Application",
                destinationPath: "/Volumes/Example Disk/Example Application",
                backupPath: "/Synthetic/Library/Application Support/Example Application.backup",
                sourceIdentity: DataPathIdentity(device: 1, inode: 1), phase: .cleanupRequested,
                recoverableReason: "部分数据操作尚未完成，已保留副本。".localized)
            for scheme in [ColorScheme.light, .dark] {
                let prefix = "localization-\(language)-\(scheme)"
                func localized<V: View>(_ view: V) -> some View {
                    view.environment(\.locale, locale).environment(\.layoutDirection, direction)
                }
                try await render(localized(MigrationTaskList(center: center)),
                    size: NSSize(width: 420, height: 280),
                    to: output.appendingPathComponent("\(prefix)-tasks.png"), colorScheme: scheme)
                try await render(localized(MigrationTaskDetail(job: job, center: center)),
                    size: NSSize(width: 460, height: 420),
                    to: output.appendingPathComponent("\(prefix)-detail.png"), colorScheme: scheme)
                try await render(localized(DataCleanupResolutionSheet(transfers: [transfer],
                    currentDataPaths: [transfer.id: transfer.activePath],
                    onRetry: { _ in XCTFail("Rendering must not retry a migration") },
                    onChanged: { XCTFail("Rendering must not change a record") },
                    onPermissions: { XCTFail("Rendering must not open system settings") })),
                    size: NSSize(width: 620, height: 460),
                    to: output.appendingPathComponent("\(prefix)-recovery.png"), colorScheme: scheme)
                for creating in [true, false] {
                    try await render(localized(APFSVolumePasswordSheet(isCreating: creating, onConfirm: { _ in
                        XCTFail("Rendering must not create or unlock a volume")
                    })), size: NSSize(width: 440, height: creating ? 400 : 340),
                    to: output.appendingPathComponent("\(prefix)-password-\(creating ? "create" : "unlock").png"),
                    colorScheme: scheme)
                }
            }
        }
    }

    @MainActor
    func testRenderAPFSRecoveryEntryPoints() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"] else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to export recovery renders")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = URL(fileURLWithPath: "/Users/example/Library/Containers/org.example/Data/Documents")
        var item = DataDirItem(name: "Documents", path: original, type: .containers, priority: .critical, description: "")
        item.status = DataDirStatus.volumeMissing
        let missing = item
        item.status = DataDirStatus.local
        item.isMigratable = false
        item.hasMountTransferRecord = true
        item.recoveryOperationID = UUID()
        let interrupted = item
        try await render(VStack(alignment: .leading, spacing: 24) {
            HStack { Text("外置盘未连接"); Spacer(); self.actions(for: missing) }
            HStack { Text("还原中断"); Spacer(); self.actions(for: interrupted) }
        }.padding(24), size: NSSize(width: 480, height: 180), to: output.appendingPathComponent("recovery-entry-points.png"))
    }

    @MainActor
    func testRenderMigrationSafetyComponents() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to export the synthetic render matrix")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let items = fixtureItems()
        for (name, title, stage) in [
            ("data-backup-progress", "正在备份原始应用".localized, DataTransferStage.preparing),
            ("data-signing-progress", "重签名此应用".localized, .verifying),
            ("data-cleanup-progress", "正在清理旧副本...".localized, .cleaning),
            // Application transfers now use the same stage-aware overlay.
            ("app-transfer-preparing", "正在迁移应用...".localized, DataTransferStage.preparing),
            ("app-transfer-synchronizing", "正在迁移应用...".localized, .synchronizing)
        ] {
            let progress = DataTransferProgress()
            progress.begin(stage, currentFile: "Example.app")
            try await render(DataDirProgressOverlay(title: title, progress: progress),
                             size: NSSize(width: 540, height: 340), to: output.appendingPathComponent("\(name).png"))
        }
        // The copying stage is the only one with a determinate bar; render it with
        // real byte totals so the layout can be checked.
        do {
            let progress = DataTransferProgress()
            progress.begin(.copying, currentFile: "Contents/Frameworks/Example")
            progress.update(FileCopier.Progress(copiedBytes: 1_240_000_000, totalBytes: 3_700_000_000,
                currentFile: "Contents/Frameworks/Example"))
            try await render(DataDirProgressOverlay(title: "正在迁移应用".localized, progress: progress),
                             size: NSSize(width: 540, height: 340),
                             to: output.appendingPathComponent("app-transfer-copying.png"))
        }
        for width: CGFloat in [580, 900] {
            for zeros in [false, true] {
                for locked in [false, true] {
                    let matches = Set(items.filter {
                        $0.matchesVisibility(showZeroByteDirectories: zeros, showNonMigratableDirectories: false)
                    }.map(\.id))
                    let tree = DataDirTree.visibleTree(from: items, showZeroByteDirectories: zeros, showLockedStructure: locked,
                                                       matchingIDs: matches, showNonMigratableDirectories: false)
                    let view = VStack(alignment: .leading, spacing: 8) {
                        AppDataVisibilityControls(showZeroByteDirectories: .constant(zeros),
                                                  showLockedStructure: .constant(locked),
                                                  showNonMigratableDirectories: .constant(false))
                            .padding(.horizontal, 12)
                        AppDataDirectoryBrowser(groups: [DataDirGroup(type: .containers, items: tree)],
                                                matchingItemIDs: matches, isFiltering: false, showLockedStructure: locked) { item in
                            self.actions(for: item)
                        }
                    }
                    .padding(.top, 12)
                    .background(Color(nsColor: .windowBackgroundColor))
                    try await render(view, size: NSSize(width: width, height: 940),
                               to: output.appendingPathComponent("browser-\(Int(width))-zeros-\(zeros)-locked-\(locked).png"))
                }
            }
        }

        let normalized = try XCTUnwrap(items.first { $0.status == DataDirStatus.needsNormalization })
        try await render(HStack(spacing: 6) { actions(for: normalized) }.frame(width: 180, height: 80), size: NSSize(width: 180, height: 80),
                   to: output.appendingPathComponent("normalize-and-restore-actions.png"))
        print("Synthetic migration UI renders: \(output.path)")
    }

    @MainActor
    func testRenderDataTransferProgressStages() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to render transfer progress")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let originalLanguage = LanguageManager.shared.language
        defer { LanguageManager.shared.language = originalLanguage }
        let cases: [(String, DataTransferStage, Int64, Int64, Int, TimeInterval)] = [
            ("preparing", .preparing, 0, 0, 0, 0),
            ("scanning", .scanning, 0, 0, 12_431, 0),
            ("copying", .copying, 18_330_000_000, 36_660_000_000, 0, 0),
            ("verifying", .verifying, 36_660_000_000, 36_660_000_000, 26_012, 0),
            ("switching", .switching, 36_660_000_000, 36_660_000_000, 0, 0),
            ("cleaning", .cleaning, 36_660_000_000, 36_660_000_000, 41_520, 0),
            ("waiting", .synchronizing, 36_660_000_000, 36_660_000_000, 0, 25)
        ]
        for language in ["zh-Hans", "en"] {
            LanguageManager.shared.language = language
            for scheme in [ColorScheme.light, .dark] {
                for (name, stage, copied, total, items, age) in cases {
                    let fractions: [DataTransferStage: Double] = [.preparing: 0.03, .scanning: 0.05,
                        .copying: 0.375, .verifying: 0.72, .switching: 0.88, .cleaning: 0.94, .synchronizing: 0.55]
                    let snapshot = DataTransferProgress.Snapshot(stage: stage,
                        directoryPath: "/example/msg",
                        currentFile: stage == .preparing ? "" : "Data/Documents/xwechat_files/Example Account With A Long Name/db_storage/message/message_0.db",
                        completedItems: items, readBytes: items > 0 ? 4_290_000_000 : 0,
                        copiedBytes: copied, totalBytes: total, copyBytesPerSecond: 93_000_000,
                        unitFraction: fractions[stage] ?? 0,
                        unitCount: 2, hasStartedCopy: copied > 0, hasEnteredEntrySwitch: stage == .switching, hasEnteredCleanup: stage == .cleaning,
                        startedAt: 0, stageStartedAt: 60, lastActivityAt: 143 - age, sampledAt: 143)
                    let title = String(format: "正在挂载迁移「%@」".localized,
                        "Containers: Data/Documents/xwechat_files/Example Account With A Long Name")
                    try await render(DataDirProgressContent(title: title, snapshot: snapshot,
                        overallProgress: snapshot.overallFraction),
                        size: NSSize(width: 540, height: 440),
                        to: output.appendingPathComponent("progress-\(language)-\(scheme)-\(name).png"), colorScheme: scheme)
                }
            }
        }
    }

    @MainActor
    func testNavigationRequestScrollsToDistantDirectory() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to verify synthetic navigation")
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let items = (0..<80).map { index in
            DataDirItem(name: "Directory \(index)", path: URL(fileURLWithPath: "/Synthetic/Directory-\(index)"),
                        type: .containers, priority: .optional, description: "", status: DataDirStatus.linked)
        }
        let controller = NavigationRenderController()
        let view = NavigationRenderHarness(controller: controller, items: items)
        try await render(view, size: NSSize(width: 580, height: 740),
                   to: URL(fileURLWithPath: path).appendingPathComponent("summary-navigation.png"),
                   afterLayout: { controller.request = .init(itemIDs: [items[70].id]) }, requiresNavigation: true)
    }

    @MainActor
    func testMountedSummaryShowsOnlyBothMatchingDirectories() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to verify synthetic summary filtering")
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let root = "/AppPortsSyntheticHome/Library/Containers/com.example.summary/Data"
        func item(_ relative: String, status: String = DataDirStatus.local) -> DataDirItem {
            let url = URL(fileURLWithPath: root + "/" + relative)
            var value = DataDirItem(name: url.lastPathComponent, path: url, type: .containers,
                                    priority: .optional, description: "Synthetic summary filter", status: status)
            value.applySize(DirectorySizeResult(bytes: 1_048_576))
            return value
        }
        let first = item("Documents/Account", status: DataDirStatus.mounted)
        let second = item("Library/Caches/Archive", status: DataDirStatus.pendingMount)
        let unrelated = (0..<80).map { item("Documents/Unrelated-\($0)") }
        let items = [item(""), item("Documents"), first] + unrelated
            + [item("Library"), item("Library/Caches"), second]
        let tree = DataDirTree.summaryTree(from: items, filter: .mounted)
        XCTAssertEqual(DataDirTree.rows(in: tree).map(\.id), [first.id, second.id],
                       "Filtering must remove unrelated rows and structural parents, retaining both matches")
        let view = AppDataDirectoryBrowser(groups: [DataDirGroup(type: .containers, items: tree)],
            matchingItemIDs: [first.id, second.id], isFiltering: true) { item in self.actions(for: item) }
        try await render(view, size: NSSize(width: 900, height: 740),
                         to: URL(fileURLWithPath: path).appendingPathComponent("summary-filter.png"),
                         expectedTableRowCount: 3)
    }

    @MainActor
    private final class NavigationRenderController: ObservableObject {
        @Published var request: DataDirTree.RevealRequest?
    }

    private struct NavigationRenderHarness: View {
        @ObservedObject var controller: NavigationRenderController
        let items: [DataDirItem]
        var body: some View {
            AppDataDirectoryBrowser(groups: [DataDirGroup(type: .containers, items: items)],
                matchingItemIDs: Set(items.map(\.id)), isFiltering: false,
                revealRequest: controller.request) { _ in EmptyView() }
        }
    }

    @MainActor
    func testInformationHeightRestoresInRecreatedBrowser() async throws {
        guard let output = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"] else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to export renders")
        }
        let suite = "AppPortsHeightTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "appDataDirectoryInformationPanelHeight"
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = fixtureItems()
        func browser() -> some View {
            AppDataDirectoryBrowser(groups: [DataDirGroup(type: .containers, items: DataDirTree.build(from: items))],
                matchingItemIDs: Set(items.map(\.id)), isFiltering: false) { _ in EmptyView() }
        }
        func tableHeight(_ view: NSView) -> CGFloat? {
            if let table = view as? NSTableView { return table.enclosingScrollView?.frame.height }
            return view.subviews.compactMap(tableHeight).first
        }
        var compact: CGFloat?
        try await render(browser(), size: NSSize(width: 900, height: 740),
                         to: directory.appendingPathComponent("height-default.png"), defaults: defaults,
                         inspect: { compact = tableHeight($0) })
        XCTAssertNil(defaults.object(forKey: key), "Rendering must not overwrite the saved preference")
        defaults.set(248.0, forKey: key)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        var expanded: CGFloat?
        try await render(browser(), size: NSSize(width: 900, height: 740),
                         to: directory.appendingPathComponent("height-restored.png"), defaults: reopened,
                         inspect: { expanded = tableHeight($0) })
        XCTAssertEqual(try XCTUnwrap(compact) - XCTUnwrap(expanded), 200, accuracy: 1,
                       "Recreating the browser restores 248pt instead of the initial 48pt")
        try await render(browser(), size: NSSize(width: 900, height: 300),
                         to: directory.appendingPathComponent("height-small-window.png"), defaults: reopened)
        XCTAssertEqual(reopened.double(forKey: key), 248,
                       "A smaller window clamps display without losing the user's preferred height")
    }

    @MainActor
    private func actions(for item: DataDirItem) -> some View {
        DataDirOperationButtons(item: item, onMigrate: { _ in }, onRestore: { _ in },
                                onManageExistingLink: { _ in }, onNormalizeManagedLink: { _ in },
                                onRelinkExternalData: { _ in }, onMountMigrate: { _ in },
                                onMount: { _ in }, onUnmount: { _ in }, onMountRestore: { _ in }, inline: true)
    }

    @MainActor
    private func render<V: View>(_ view: V, size: NSSize, to url: URL, requiresScrolling: Bool = false,
                                 afterLayout: (() -> Void)? = nil, requiresNavigation: Bool = false,
                                 expectedTableRowCount: Int? = nil, defaults: UserDefaults? = nil,
                                 inspect: ((NSView) -> Void)? = nil, colorScheme: ColorScheme = .light) async throws {
        let suite = "AppPortsRender-\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(defaults ?? UserDefaults(suiteName: suite))
        defer { if defaults == nil { isolatedDefaults.removePersistentDomain(forName: suite) } }
        let appearance = try XCTUnwrap(NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua))
        let originalAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = originalAppearance }
        let host = NSHostingView(rootView: view.defaultAppStorage(isolatedDefaults).environment(\.colorScheme, colorScheme)
            .background(colorScheme == .dark ? Color.black : Color.white))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        defer { window.close() }
        window.contentView = host
        // Realize native control layers before capturing, without showing a
        // test window over the user's workspace.
        window.setFrameOrigin(NSPoint(x: -10_000, y: 0))
        window.orderFront(nil)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Lists settle their lazy AppKit layout on the next run-loop turn.
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let afterLayout {
            afterLayout()
            try await Task.sleep(nanoseconds: 300_000_000)
            host.layoutSubtreeIfNeeded()
        }
        if requiresNavigation {
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            let table = try XCTUnwrap(scrollViews(host).compactMap { $0.documentView as? NSTableView }.first)
            for attempt in 0..<2 {
                if attempt == 1 {
                    let scroll = try XCTUnwrap(table.enclosingScrollView)
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    afterLayout?() // Same target IDs, new click token.
                    try await Task.sleep(nanoseconds: 300_000_000)
                    host.layoutSubtreeIfNeeded()
                }
                XCTAssertEqual(table.selectedRow, 71, "One section header precedes synthetic Directory-70")
                XCTAssertTrue(NSLocationInRange(table.selectedRow, table.rows(in: table.visibleRect)),
                              "The selected target must actually be visible, including after a repeated click")
            }
        }
        if let expectedTableRowCount {
            func tables(in view: NSView) -> [NSTableView] {
                (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
            }
            let table = try XCTUnwrap(tables(in: host).first)
            XCTAssertEqual(table.numberOfRows, expectedTableRowCount,
                           "The rendered list must contain just two matches and their section header")
            for row in 1..<expectedTableRowCount {
                XCTAssertTrue(NSLocationInRange(row, table.rows(in: table.visibleRect)),
                              "Both matching directories should be visible together")
            }
        }
        if requiresScrolling {
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            let scroll = try XCTUnwrap(scrollViews(in: host).first)
            let content = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(content.frame.height, scroll.contentView.bounds.height,
                                 "Long recovery details must remain reachable by scrolling")
        }
        inspect?(host)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 1, "Export an opaque, reviewable snapshot")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000, "The production view should render visible content")
        try png.write(to: url)
        print("Rendered \(url.lastPathComponent): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }

    /// Exports the target-volume capability warning exactly as the user sees it.
    ///
    /// The warning is the one place where a relaxed app copy explains what it
    /// will not preserve, so it is worth reviewing as pixels rather than as a
    /// string constant.
    @MainActor
    func testRenderStorageCapabilityWarning() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to export the storage capability warning")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let full = StorageCapabilities(supportsACL: false, supportsHardlinks: false,
                                       supportsResourceFork: false, supportsPermissions: false)
        let aclOnly = StorageCapabilities(supportsACL: false, supportsHardlinks: true,
                                          supportsResourceFork: true, supportsPermissions: true)

        for (name, capabilities, drive) in [
            ("storage-capability-warning-full", full, "My Passport"),
            ("storage-capability-warning-acl-only", aclOnly, "USB Stick")
        ] {
            let request = storageLimitationRequest(capabilities: capabilities, driveName: drive)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "-dark" : ""
                try await render(WarningSheet(request), size: NSSize(width: 520, height: 520),
                                 to: output.appendingPathComponent("\(name)\(suffix).png"),
                                 colorScheme: scheme)
            }
        }
    }

    /// Exports the restore-time warning in both appearances.
    ///
    /// This is the counterpart of the migration warning: it explains that the
    /// external copy was already written without attributes the volume cannot
    /// hold, so restoring brings the loss home instead of fixing it.
    @MainActor
    func testRenderDegradedRestoreWarning() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to export the degraded restore warning")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let missing: [StorageCapabilities.Missing] = [.acl, .hardlinks, .resourceFork, .permissions]
        let items = missing.map { $0.localizedDescription }.joined(separator: "\n")
        let request = WarningSheetRequest(
            title: "外部存储上的应用包可能已降级".localized,
            tint: .orange,
            intro: String(format: "以下应用目前存放在「%@」上，这块磁盘不支持以下项目：\n\n%@\n\n这些应用是在迁出时被复制到这里的，当时就已经无法保留上述信息。还原会把这份副本复制回本机，但无法补回已经丢失的部分——还原完成后，外部原件会被删除，这些缺失将变成永久的。\n\n如果这些应用对权限或访问控制有要求，建议不要在此时还原，而是重新安装官方版本。".localized, "My Passport", items),
            documentationURL: DocumentationLink.url(page: "storage-capabilities", anchor: "degraded"),
            cancelTitle: "取消".localized,
            actions: [WarningAction("仍要还原".localized, style: .preferred) {}])

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "-dark" : ""
            try await render(WarningSheet(request), size: NSSize(width: 520, height: 560),
                             to: output.appendingPathComponent("degraded-restore-warning\(suffix).png"),
                             colorScheme: scheme)
        }
    }

    /// Mirrors `ContentView.makeStorageLimitationRequest` so the render uses the
    /// production strings, bullet list and documentation link without standing up
    /// the whole main window.
    private func storageLimitationRequest(capabilities: StorageCapabilities, driveName: String) -> WarningSheetRequest {
        let items = capabilities.missing.map { $0.localizedDescription }.joined(separator: "\n")
        return WarningSheetRequest(
            title: "迁移目标无法保存部分应用信息".localized,
            tint: .orange,
            intro: String(format: "目标磁盘「%@」不支持以下项目：\n\n%@\n\n迁移后应用仍可正常打开和使用，应用签名校验也仍然通过。但上面这些信息无法保留：文件权限会变成磁盘的固定默认值，部分应用内部共用的文件会各存一份（占用更多空间），少数应用的自定义图标等资源可能缺失。\n\n如果这个应用带有需要管理员权限的后台服务，迁移后可能无法正常工作。这种情况建议改用 APFS 格式的磁盘。".localized, driveName, items),
            documentationURL: DocumentationLink.url(page: "storage-capabilities", anchor: "summary"),
            cancelTitle: "取消".localized,
            actions: [WarningAction("仍要迁移".localized, style: .preferred) {}])
    }

    private func fixtureItems() -> [DataDirItem] {
        let root = "/AppPortsSyntheticHome/Library/Containers/com.example.visual/Data"
        func item(_ relative: String, bytes: Int64 = 0, locked: Bool = false,
                  status: String = DataDirStatus.local) -> DataDirItem {
            let path = URL(fileURLWithPath: relative.isEmpty ? root : root + "/" + relative)
            var value = DataDirItem(name: path.lastPathComponent, path: path, type: .containers,
                                    priority: .critical, description: "Synthetic render fixture")
            value.applySize(DirectorySizeResult(bytes: bytes))
            value.status = status
            value.requiresMountMigration = true
            if locked {
                value.applyPathPolicy(.init(role: .systemDirectory, reason: .systemManagedStructure,
                                            canMigrate: false, mayDiscoverChildren: true))
            }
            return value
        }
        var legacy = item("Library/Application Support/Legacy Account", bytes: 2_147_483_648,
                          status: DataDirStatus.needsNormalization)
        legacy.linkedDestination = URL(fileURLWithPath: "/Volumes/Synthetic Disk/Old Layout/Legacy Account")
        var unreadable = item("Library/Caches/Unreadable Account", bytes: 131_072, locked: true)
        unreadable.sizeIsIncomplete = true
        unreadable.applyPathPolicy(.init(role: .businessData, reason: .readFailure, canMigrate: false, mayDiscoverChildren: false))
        var desktop = item("Desktop", locked: true, status: DataDirStatus.existingSymlink)
        desktop.linkedDestination = URL(fileURLWithPath: "/AppPortsSyntheticHome/Desktop")
        desktop.applySize(DirectorySizeResult())
        return [desktop, item("", bytes: 42_000_131_072, locked: true), item("Documents", bytes: 42_000_000_000, locked: true),
                item("Documents/Account With A Long Descriptive Name", bytes: 42_000_000_000),
                item("Documents/Mounted Account", bytes: 10_970_000_000, status: DataDirStatus.mounted),
                item("Documents/Empty Account"), item("Documents/Offline Archive", status: DataDirStatus.volumeMissing),
                item("Library", bytes: 131_072, locked: true), item("Library/Application Support", locked: true), legacy,
                item("Library/Caches", bytes: 131_072, locked: true), unreadable, item("tmp", locked: true)]
    }

    private func fixtureTransfer(phase: DataTransferRecord.Phase, mode: DataTransferRecord.Mode = .symlink,
                                 direction: DataTransferRecord.Direction = .migrate) -> DataTransferRecord {
        let original = "/AppPortsSyntheticHome/Library/Containers/com.example.visual/Data/Documents/Account"
        let destination = direction == .restore ? original : "/Volumes/Synthetic External Disk/AppPorts/Library/Containers/com.example.visual/Account"
        let uuid = "11111111-2222-3333-4444-555555555555"
        return DataTransferRecord(mode: mode, direction: direction, appName: "Synthetic Application", dataDirType: "containers",
            originalPath: original, activePath: direction == .restore || phase == .needsRecovery ? original : destination, destinationPath: destination,
            backupPath: "/AppPortsSyntheticHome/Library/Containers/com.example.visual/Data/Documents/.appports-migration-backup-Account-00000000",
            stagingPath: "/AppPortsSyntheticHome/Library/Containers/com.example.visual/Data/Documents/.appports-restore-00000000/data",
            sourceIdentity: DataPathIdentity(device: 1, inode: 100, volumeUUID: uuid),
            destinationIdentity: DataPathIdentity(device: 2, inode: 200, volumeUUID: uuid),
            backupIdentity: DataPathIdentity(device: 1, inode: 100, volumeUUID: uuid), phase: phase,
            baseline: phase == .awaitingUserVerification ? Data([1]) : nil,
            recoverableReason: phase == .needsRecovery ? "Synthetic interruption after copy verification; both recorded copies remain available." : nil)
    }
}
