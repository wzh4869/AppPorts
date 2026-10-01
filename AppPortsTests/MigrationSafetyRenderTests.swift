import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

/// Opt-in visual evidence from production components and synthetic models only.
/// Run with TEST_RUNNER_APPPORTS_RENDER_UI_OUTPUT=/absolute/output/directory.
/// No DataDirsView, scanner, migration service, or persistent setting is instantiated.
final class MigrationSafetyRenderTests: XCTestCase {
    @MainActor
    func testRenderMigrationSafetyComponents() throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to export the synthetic render matrix")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let items = fixtureItems()
        for width: CGFloat in [580, 900] {
            for zeros in [false, true] {
                for locked in [false, true] {
                    let matches = Set(items.filter {
                        $0.matchesVisibility(showZeroByteDirectories: zeros, showLockedStructure: locked)
                    }.map(\.id))
                    let tree = DataDirTree.retainingMatches(in: DataDirTree.build(from: items), matchingIDs: matches)
                    let view = VStack(alignment: .leading, spacing: 8) {
                        AppDataVisibilityControls(showZeroByteDirectories: .constant(zeros), showLockedStructure: .constant(locked))
                            .padding(.horizontal, 12)
                        AppDataDirectoryBrowser(groups: [DataDirGroup(type: .containers, items: tree)],
                                                matchingItemIDs: matches, isFiltering: false, showLockedStructure: locked) { item in
                            self.actions(for: item)
                        }
                    }
                    .padding(.top, 12)
                    .background(Color(nsColor: .windowBackgroundColor))
                    try render(view, size: NSSize(width: width, height: 940),
                               to: output.appendingPathComponent("browser-\(Int(width))-zeros-\(zeros)-locked-\(locked).png"))
                }
            }
        }

        let retained = fixtureTransfer(phase: .awaitingUserVerification)
        try render(DataTransferReviewView(transfer: retained, onCleanup: {}), size: NSSize(width: 580, height: 570),
                   to: output.appendingPathComponent("retained-copy.png"))
        let incomplete = fixtureTransfer(phase: .needsRecovery)
        try render(DataTransferReviewView(transfer: incomplete, onCleanup: {}), size: NSSize(width: 580, height: 720),
                   to: output.appendingPathComponent("incomplete-copy.png"))
        let mountRestore = fixtureTransfer(phase: .awaitingUserVerification, mode: .mount, direction: .restore)
        try render(DataTransferReviewView(transfer: mountRestore, onCleanup: {}), size: NSSize(width: 580, height: 570),
                   to: output.appendingPathComponent("retained-restore-volume.png"))
        var longRecovery = incomplete
        longRecovery.recoverableReason = Array(repeating: "Synthetic recovery detail: verify both copies before making changes.", count: 40).joined(separator: "\n")
        try render(DataTransferReviewView(transfer: longRecovery, onCleanup: {}), size: NSSize(width: 580, height: 720),
                   to: output.appendingPathComponent("long-recovery-scroll.png"), requiresScrolling: true)

        let normalized = try XCTUnwrap(items.first { $0.status == DataDirStatus.needsNormalization })
        try render(HStack(spacing: 6) { actions(for: normalized) }.frame(width: 180, height: 80), size: NSSize(width: 180, height: 80),
                   to: output.appendingPathComponent("normalize-and-restore-actions.png"))
        print("Synthetic migration UI renders: \(output.path)")
    }

    @MainActor
    private func actions(for item: DataDirItem) -> some View {
        DataDirOperationButtons(item: item, onMigrate: { _ in }, onRestore: { _ in },
                                onManageExistingLink: { _ in }, onNormalizeManagedLink: { _ in },
                                onRelinkExternalData: { _ in }, onMountMigrate: { _ in },
                                onMount: { _ in }, onUnmount: { _ in }, onMountRestore: { _ in }, inline: true)
    }

    @MainActor
    private func render<V: View>(_ view: V, size: NSSize, to url: URL, requiresScrolling: Bool = false) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(Color.white))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Lists settle their lazy AppKit layout on the next run-loop turn.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { window.close() }
        if requiresScrolling {
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            let scroll = try XCTUnwrap(scrollViews(in: host).first)
            let content = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(content.frame.height, scroll.contentView.bounds.height,
                                 "Long recovery details must remain reachable by scrolling")
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 1, "Export an opaque, reviewable snapshot")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000, "The production view should render visible content")
        try png.write(to: url)
        print("Rendered \(url.lastPathComponent): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
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
        return [item("", locked: true), item("Documents", locked: true),
                item("Documents/Account With A Long Descriptive Name", bytes: 42_000_000_000),
                item("Documents/Empty Account"), item("Documents/Offline Archive", status: DataDirStatus.volumeMissing),
                item("Library", locked: true), item("Library/Application Support", locked: true), legacy,
                item("Library/Caches", locked: true), unreadable, item("tmp", locked: true)]
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
