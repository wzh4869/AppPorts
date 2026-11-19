import XCTest
@testable import AppPorts

final class DataDirSpaceSummaryTests: XCTestCase {
    func testUnresolvedIdentityMakesEmptySummaryIncomplete() {
        XCTAssertTrue(DataDirSpaceSummary(items: [], allItems: [], hasIdentityIssue: true).isIncomplete)
        XCTAssertFalse(DataDirSpaceSummary(items: [], allItems: []).isIncomplete)
    }

    func testNameMatchedDataKeepsSizeButIsNotACompleteEstimate() {
        let cache = item("/Library/Caches/wpsoffice", bytes: 500)
        let summary = DataDirSpaceSummary(items: [cache], allItems: [cache], hasIdentityIssue: true)
        XCTAssertEqual(summary.reclaimableBytes, 500)
        XCTAssertTrue(summary.isIncomplete)
        XCTAssertFalse(summary.isCalculating)
    }

    func testResolvingIdentityDoesNotHideRemainingDirectoryReadErrors() {
        XCTAssertTrue(DataDirSpaceSummary(items: [], allItems: [], hasReadIssues: true, hasIdentityIssue: false).isIncomplete)
    }

    func testProtectedWeChatParentsDoNotHideOrInflateMigratableChildren() {
        let items = [
            item("/Data/Documents", bytes: 9000, migratable: false),
            item("/Data/Documents/xwechat_files", bytes: 6000, migratable: false),
            item("/Data/Documents/xwechat_files/account", bytes: 5000),
            item("/Data/Documents/xwechat_files/Backup", bytes: 1000),
            item("/Data/Library", bytes: 4000, migratable: false),
            item("/Data/Library/Application Support", bytes: 3500, migratable: false),
            item("/Data/Library/Application Support/com.tencent.xinWeChat", bytes: 3000)
        ]

        let summary = DataDirSpaceSummary(items: items, allItems: items)

        XCTAssertEqual(summary.reclaimableBytes, 9000)
        XCTAssertFalse(summary.isCalculating)
        XCTAssertFalse(summary.isIncomplete)
    }

    func testParentsChildrenAndDuplicatePathsAreCountedOnce() {
        let parent = item("/Data/Cache", bytes: 1000)
        let child = item("/Data/Cache/Images", bytes: 800)
        let other = item("/Data/CacheBackup", bytes: 500)
        let items = [child, parent, other, parent]

        XCTAssertEqual(DataDirSpaceSummary(items: items, allItems: items).reclaimableBytes, 1500)
    }

    func testMountedDescendantsDoNotReduceAlreadyLocalParentMeasurement() {
        let items = [
            item("/Data", bytes: 1000),
            item("/Data/External", bytes: 800, status: DataDirStatus.mounted),
            item("/Data/External/Nested", bytes: 100, status: DataDirStatus.mounted),
            item("/Data/External/AppData", bytes: 200)
        ]

        XCTAssertEqual(DataDirSpaceSummary(items: items, allItems: items).reclaimableBytes, 1000)
    }

    func testFilteringToAChildOfAnExternalDirectoryDoesNotMakeItReclaimable() {
        let child = item("/Data/Linked/account", bytes: 1000)
        for status in [DataDirStatus.linked, DataDirStatus.existingSymlink, DataDirStatus.mounted] {
            let parent = item("/Data/Linked", bytes: 2000, status: status)
            let summary = DataDirSpaceSummary(items: [child], allItems: [parent, child])
            XCTAssertEqual(summary.reclaimableBytes, 0, status)
        }
    }

    func testFilteringToAMigratableChildOnlyCountsTheMatchingData() {
        let parent = item("/Data", bytes: 2000)
        let child = item("/Data/Images", bytes: 1000)

        XCTAssertEqual(DataDirSpaceSummary(items: [child], allItems: [parent, child]).reclaimableBytes, 1000)
    }

    func testUnavailableLocalSizeMakesSummaryIncomplete() {
        var parent = item("/Data", bytes: 1000)
        parent.sizeIsIncomplete = true
        XCTAssertTrue(DataDirSpaceSummary(items: [parent], allItems: [parent]).isIncomplete)
    }

    func testUnreadableDiscoveryPreventsSmallVisibleDirectoriesFromLookingComplete() {
        let cache = item("/Library/Caches/com.tencent.xinWeChat", bytes: 353_000)
        let summary = DataDirSpaceSummary(items: [cache], allItems: [cache], hasReadIssues: true)
        XCTAssertTrue(summary.isIncomplete)
    }

    func testPendingMeasurementIsCalculatingAndRemainsVisible() {
        var pending = item("/Data", bytes: 0)
        pending.size = nil

        XCTAssertTrue(DataDirSpaceSummary(items: [pending], allItems: [pending]).isCalculating)
        XCTAssertFalse(pending.isEmptyLocalDirectory)
    }

    func testZeroByteFilterOnlyHidesConfirmedEmptyLocalDirectories() {
        XCTAssertTrue(item("/Data/Empty", bytes: 0).isEmptyLocalDirectory)
        XCTAssertFalse(item("/Data/Small", bytes: 1).isEmptyLocalDirectory)

        var unreadable = item("/Data/Restricted", bytes: 0)
        unreadable.applySize(DirectorySizeResult(readIssues: [
            DataDirReadIssue(url: unreadable.path, error: CocoaError(.fileReadNoPermission))
        ]))
        XCTAssertFalse(unreadable.isEmptyLocalDirectory)

        for status in [DataDirStatus.linked, DataDirStatus.existingSymlink, DataDirStatus.pendingRelink,
                       DataDirStatus.mounted, DataDirStatus.pendingMount, DataDirStatus.volumeMissing] {
            XCTAssertFalse(item("/Data/Managed", bytes: 0, status: status).isEmptyLocalDirectory, status)
        }
    }

    func testZeroByteFilteringKeepsTheAncestorsOfNonemptyChildren() {
        let parent = item("/Data", bytes: 0)
        let child = item("/Data/Files", bytes: 512)
        let empty = item("/Data/Empty", bytes: 0)
        let items = [parent, child, empty]
        let matches = Set(items.filter { !$0.isEmptyLocalDirectory }.map(\.id))

        let tree = DataDirTree.retainingMatches(in: DataDirTree.build(from: items), matchingIDs: matches)

        XCTAssertEqual(DataDirTree.rows(in: tree).map(\.id), [parent.id, child.id])
    }

    func testDisplaySummarySplitsLocalAndMigratedBytesWithParentChildDeduplication() {
        let containerRoot = item("/Library/Containers/com.example.App", bytes: 400, status: DataDirStatus.local)
        let localChild = item("/Library/Containers/com.example.App/Data", bytes: 250, status: DataDirStatus.local)
        let mountedChild = item("/Library/Containers/com.example.App/Data/Media", bytes: 1_600, status: DataDirStatus.mounted)
        let linkedSupport = item("/Library/Application Support/Example", bytes: 900, status: DataDirStatus.linked)
        let pendingRelink = item("/Library/Caches/Example", bytes: 300, status: DataDirStatus.pendingRelink)
        let restoredLocal = item("/Library/Application Support/Restored", bytes: 150, status: DataDirStatus.local)

        let summary = DataDirDisplaySizeSummary(items: [
            containerRoot, localChild, mountedChild, linkedSupport, pendingRelink, restoredLocal
        ])

        XCTAssertTrue(summary.hasMigratedItems)
        XCTAssertEqual(summary.localBytes, 550)
        XCTAssertEqual(summary.migratedBytes, 2_800)
        XCTAssertEqual(summary.bytes, 3_350)
        XCTAssertFalse(summary.isCalculating)
        XCTAssertFalse(summary.isIncomplete)
    }

    func testAppDataAppListSorterPinsMigratedAppsAndSortsEachGroupBySize() {
        func makeApp(_ name: String) -> AppItem {
            AppItem(name: name, path: URL(fileURLWithPath: "/Applications/\(name)"), status: AppStatus.local)
        }

        let migratedSmall = makeApp("MigratedSmall.app")
        let migratedLarge = makeApp("MigratedLarge.app")
        let migratedZero = makeApp("MigratedZero.app")
        let localLarge = makeApp("LocalLarge.app")
        let localPending = makeApp("LocalPending.app")
        let localZero = makeApp("LocalZero.app")

        let apps = [localZero, migratedSmall, localPending, migratedZero, localLarge, migratedLarge]
        let migratedIDs: Set<String> = [migratedSmall.id, migratedLarge.id, migratedZero.id]
        let summaries: [String: AppDataRowSizeSummary] = [
            migratedSmall.id: AppDataRowSizeSummary(localBytes: 100, migratedBytes: 400, hasMigratedItems: true, isIncomplete: false, isCalculating: false),
            migratedLarge.id: AppDataRowSizeSummary(localBytes: 200, migratedBytes: 2_000, hasMigratedItems: true, isIncomplete: false, isCalculating: false),
            migratedZero.id: AppDataRowSizeSummary(localBytes: 0, migratedBytes: 0, hasMigratedItems: true, isIncomplete: false, isCalculating: false),
            localLarge.id: AppDataRowSizeSummary(localBytes: 900, migratedBytes: 0, hasMigratedItems: false, isIncomplete: false, isCalculating: false),
            localZero.id: AppDataRowSizeSummary(localBytes: 0, migratedBytes: 0, hasMigratedItems: false, isIncomplete: false, isCalculating: false)
        ]

        let bySize = AppDataAppListSorter.ordered(apps, mode: .size, migratedAppDataIDs: migratedIDs, summaries: summaries)
        XCTAssertEqual(bySize.map(\.name), [
            "MigratedLarge.app", "MigratedSmall.app", "MigratedZero.app",
            "LocalLarge.app", "LocalPending.app", "LocalZero.app"
        ])

        let byDefault = AppDataAppListSorter.ordered(apps, mode: .defaultOrder, migratedAppDataIDs: migratedIDs, summaries: summaries)
        XCTAssertEqual(byDefault.map(\.name), [
            "MigratedSmall.app", "MigratedZero.app", "MigratedLarge.app",
            "LocalZero.app", "LocalPending.app", "LocalLarge.app"
        ])

        let byAlpha = AppDataAppListSorter.ordered(apps, mode: .alphabetical, migratedAppDataIDs: migratedIDs, summaries: summaries)
        XCTAssertEqual(byAlpha.map(\.name), [
            "MigratedLarge.app", "MigratedSmall.app", "MigratedZero.app",
            "LocalLarge.app", "LocalPending.app", "LocalZero.app"
        ])
    }

    func testDisplaySummaryDoesNotDoubleCountLocalMembersOfPartialWeChatSplit() {
        let containerRoot = item("/Library/Containers/com.tencent.xinWeChat", bytes: 900, status: DataDirStatus.local)
        let mountedMember = item(
            "/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1/msg",
            bytes: 1_000,
            status: DataDirStatus.mounted
        )
        let localMember = item(
            "/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1/business",
            bytes: 400,
            status: DataDirStatus.local
        )
        var splitRow = item(
            "/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1",
            bytes: 1_400,
            status: DataDirStatus.pendingCompletion
        )
        splitRow.weChatSplitMembers = [mountedMember, localMember]

        let summary = DataDirDisplaySizeSummary(items: [containerRoot, splitRow])
        XCTAssertTrue(summary.hasMigratedItems)
        XCTAssertEqual(summary.localBytes, 900)
        XCTAssertEqual(summary.migratedBytes, 1_000)
        XCTAssertEqual(summary.bytes, 1_900)
    }

    private func item(_ path: String, bytes: Int64, status: String = DataDirStatus.local, migratable: Bool = true) -> DataDirItem {
        var item = DataDirItem(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: URL(fileURLWithPath: path),
            type: .containers,
            priority: .critical,
            description: "",
            status: status,
            isMigratable: migratable
        )
        item.applySize(DirectorySizeResult(bytes: bytes))
        return item
    }
}
