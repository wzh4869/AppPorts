import Foundation
import Testing
@testable import AppPorts

struct DataDirPresentationTests {
    private let home = URL(fileURLWithPath: "/fixture/presentation-home")

    @Test("Unsupported directories hide while inspectable links and requested ancestors remain visible")
    func unsupportedDirectoryVisibility() {
        for status in [DataDirStatus.local, DataDirStatus.existingSymlink, DataDirStatus.linked] {
            var item = DataDirItem(name: "AddressBook", path: home.appendingPathComponent("AddressBook"),
                                   type: .containers, priority: .optional, description: "",
                                   status: status, isMigratable: false)
            item.sizeIsIncomplete = true
            let inspectable = status != DataDirStatus.local
            #expect(item.matchesVisibility(showZeroByteDirectories: true,
                                          showNonMigratableDirectories: false) == inspectable)
            #expect(item.matchesVisibility(showZeroByteDirectories: true,
                                          showNonMigratableDirectories: true))

            var child = item
            child.path = item.path.appendingPathComponent("Business")
            child.isMigratable = true
            let tree = DataDirTree.visibleTree(from: [item, child], showZeroByteDirectories: true,
                                              showLockedStructure: false, matchingIDs: [item.id, child.id],
                                              showNonMigratableDirectories: false)
            #expect(DataDirTree.rows(in: tree).map(\.id) == (inspectable ? [item.id, child.id] : [child.id]))
            let withAncestors = DataDirTree.visibleTree(from: [item, child], showZeroByteDirectories: true,
                showLockedStructure: true, matchingIDs: [item.id, child.id], showNonMigratableDirectories: false)
            #expect(DataDirTree.rows(in: withAncestors).map(\.id) == [item.id, child.id])
        }
    }

    private func shortcut(_ name: String = "Desktop") -> DataDirItem {
        DataDirItem(name: name,
                    path: home.appendingPathComponent("Library/Containers/com.example.app/Data/\(name)"),
                    type: .containers, priority: .optional, description: "",
                    status: DataDirStatus.existingSymlink, isMigratable: false,
                    linkedDestination: home.appendingPathComponent(name))
    }

    @Test("A structural shortcut with a reported conflict or read failure remains visible",
          arguments: [DataPathPolicy.Reason.runtimeConflict, .readFailure])
    func shortcutWithAttention(reason: DataPathPolicy.Reason) {
        var item = shortcut()
        item.applyPathPolicy(.init(role: .systemDirectory, reason: reason, canMigrate: false, mayDiscoverChildren: false))
        #expect(item.needsRecoveryOrAttention)
        #expect(item.matchesVisibility(showZeroByteDirectories: false, showNonMigratableDirectories: false))
        #expect(item.sizeMeasurementURL == nil)
    }

    @Test("Standard container shortcuts do not claim the user's personal files as app data",
          arguments: ["Desktop", "Downloads", "Movies", "Music", "Pictures"])
    func personalFolderShortcut(_ name: String) {
        var item = shortcut(name)
        #expect(item.isUserDirectoryLink)
        #expect(item.sizeMeasurementURL == nil)
        #expect(item.displayedStatus == "用户目录入口")
        #expect(item.sizeScopeLabel == "不计入应用数据".localized)
        #expect(!item.canRestore)

        // Even an old or accidentally supplied target measurement cannot leak into app totals.
        item.sizeIsIncomplete = true
        item.applySize(DirectorySizeResult(bytes: 10_970_000_000))
        #expect(item.sizeBytes == 0)
        #expect(item.size == "—")
        #expect(!item.sizeIsIncomplete)
        #expect(!item.needsRecoveryOrAttention)
        #expect(DataDirSpaceSummary(items: [item], allItems: [item]).reclaimableBytes == 0)
    }

    @Test("Personal folder shortcuts stay outside app data regardless of visibility toggles",
          arguments: [false, true], [false, true])
    func shortcutVisibility(showZero: Bool, showStructure: Bool) {
        let item = shortcut()
        #expect(!item.matchesVisibility(showZeroByteDirectories: showZero,
                                        showNonMigratableDirectories: showStructure))
    }

    @Test("Similar folder names and nested paths remain ordinary existing links",
          arguments: ["Documents", "DesktopExtra", "Nested/Desktop", "Library/Desktop"])
    func nonstandardSource(_ relativePath: String) {
        var item = shortcut()
        item.path = home.appendingPathComponent("Library/Containers/com.example.app/Data/\(relativePath)")
        #expect(!item.isUserDirectoryLink)
        #expect(item.sizeMeasurementURL == item.linkedDestination)
        #expect(item.displayedStatus == DataDirStatus.existingSymlink)
        #expect(item.matchesVisibility(showZeroByteDirectories: false, showNonMigratableDirectories: false))
    }

    @Test("Only the matching personal folder target qualifies",
          arguments: ["DesktopExtra", "Pictures", "Desktop/Nested", "../another-home/Desktop"])
    func nonstandardTarget(_ relativePath: String) {
        var item = shortcut()
        item.linkedDestination = home.appendingPathComponent(relativePath)
        #expect(!item.isUserDirectoryLink)
        #expect(item.sizeMeasurementURL == item.linkedDestination)
    }

    @Test("Non-container paths and types cannot acquire shortcut presentation")
    func wrongLocationOrType() {
        var item = shortcut()
        item.type = .custom
        #expect(!item.isUserDirectoryLink)
        item.type = .containers
        for relativePath in ["Library/Group Containers/com.example.app/Data/Desktop",
                             "Library/ContainersExtra/com.example.app/Data/Desktop",
                             "Other/Containers/com.example.app/Data/Desktop"] {
            item.path = home.appendingPathComponent(relativePath)
            #expect(!item.isUserDirectoryLink)
        }
        item = shortcut()
        item.linkedDestination = nil
        #expect(!item.isUserDirectoryLink)
        #expect(item.sizeMeasurementURL == item.path)
    }

    @Test("Managed and recovery links retain their inspection and recovery visibility")
    func managedOrRecoveryLinks() {
        var managed = shortcut()
        managed.hasManagedLinkRecord = true
        var recovery = shortcut()
        recovery.recoveryOperationID = UUID()
        var linked = shortcut()
        linked.status = DataDirStatus.linked
        var normalizing = shortcut()
        normalizing.status = DataDirStatus.needsNormalization
        for item in [managed, recovery, linked, normalizing] {
            #expect(!item.isUserDirectoryLink)
            #expect(item.sizeMeasurementURL == item.linkedDestination)
            #expect(item.displayedStatus == item.status)
            #expect(item.needsRecoveryOrAttention)
            #expect(item.matchesVisibility(showZeroByteDirectories: false, showNonMigratableDirectories: false))
        }
        #expect(managed.canRestore)
        #expect(linked.canRestore)
        #expect(normalizing.canRestore)
    }

    @Test("Scope labels describe measurements without adding mounted descendants")
    func independentSizeScopes() {
        var parent = shortcut()
        parent.status = DataDirStatus.local
        parent.linkedDestination = nil
        parent.path = home.appendingPathComponent("Library/Containers/com.example.app/Data/Documents/xwechat_files")
        parent.applySize(DirectorySizeResult(bytes: 442_000))
        var mounted = parent
        mounted.path = parent.path.appendingPathComponent("account")
        mounted.status = DataDirStatus.mounted
        mounted.applySize(DirectorySizeResult(bytes: 10_970_000_000))
        parent.children = [mounted]
        #expect(parent.sizeScopeLabel == "本卷大小".localized)
        #expect(mounted.sizeScopeLabel == "本卷大小".localized)
        #expect(parent.sizeBytes == 442_000)
        #expect(mounted.sizeBytes == 10_970_000_000)

        var link = shortcut()
        link.linkedDestination = URL(fileURLWithPath: "/fixture/external/business")
        link.applySize(DirectorySizeResult(bytes: 8_192))
        #expect(link.sizeScopeLabel == "目标大小".localized)
        #expect(link.sizeBytes == 8_192)
        #expect(link.sizeMeasurementURL == link.linkedDestination)
    }

    @Test("macOS sandbox Library convenience links mirror ~/Library and never masquerade as app data",
          arguments: [
            "Library/Mail",
            "Library/Keychains",
            "Library/Dictionaries",
            "Library/Sounds",
            "Library/Application Support/iCloud",
            "Library/Application Support/SyncServices",
            "Library/Application Scripts/com.tencent.xinWeChat",
            "Library/Images/People",
            "Library/Preferences/com.apple.security.plist"
          ])
    func sandboxLibraryConvenienceLinks(_ relativePath: String) {
        let item = DataDirItem(
            name: relativePath,
            path: home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/\(relativePath)"),
            type: .containers, priority: .optional, description: "",
            status: DataDirStatus.existingSymlink, isMigratable: false,
            linkedDestination: home.appendingPathComponent(relativePath)
        )
        #expect(item.isUserDirectoryLink)
        #expect(!item.isPersonalFolderShortcut)
        #expect(item.sizeMeasurementURL == nil)
        #expect(!item.canRestore)
        #expect(!item.needsRecoveryOrAttention)
        #expect(!item.matchesVisibility(showZeroByteDirectories: true, showNonMigratableDirectories: true))
    }

    @Test("Protected structural container directories and mismatched Library targets stay inspectable",
          arguments: [
            ("Library", "Library"),
            ("Library/Application Support", "Library/Application Support"),
            ("Library/Preferences", "Library/Preferences"),
            ("Documents", "Documents"),
            ("Library/Mail", "Library/Keychains"),
            ("Library/Mail", "Desktop")
          ])
    func nonSandboxLibraryLinksStayInspectable(_ sourceRelative: String, _ targetRelative: String) {
        let item = DataDirItem(
            name: sourceRelative,
            path: home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/\(sourceRelative)"),
            type: .containers, priority: .optional, description: "",
            status: DataDirStatus.existingSymlink, isMigratable: false,
            linkedDestination: home.appendingPathComponent(targetRelative)
        )
        #expect(!item.isUserDirectoryLink)
        #expect(item.needsRecoveryOrAttention)
        #expect(item.matchesVisibility(showZeroByteDirectories: false, showNonMigratableDirectories: false))
    }
}
