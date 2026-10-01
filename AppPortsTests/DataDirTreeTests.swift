import XCTest
@testable import AppPorts

final class DataDirTreeTests: XCTestCase {
    func testMountedSummaryShowsOnlyTwoDistantMatchesAndPreservesTheirContext() {
        let data = item("/Library/Containers/com.example.app/Data")
        let documents = item(data.id + "/Documents")
        var account = item(documents.id + "/xwechat_files/account")
        account.status = DataDirStatus.mounted
        var cache = item(data.id + "/Library/Caches/files")
        cache.status = DataDirStatus.mounted
        let unrelated = item(documents.id + "/xwechat_files/all_users")

        let rows = DataDirTree.rows(in: DataDirTree.summaryTree(
            from: [data, documents, account, unrelated, cache], filter: .mounted))

        XCTAssertEqual(rows.map(\.id), [account.id, cache.id])
        XCTAssertEqual(rows.map(\.level), [0, 0])
        XCTAssertEqual(rows.map(\.contextPath), [documents.id + "/xwechat_files", data.id + "/Library/Caches"])
    }

    func testMountedSummaryIncludesPendingAndMissingVolumesButNotOtherStatuses() {
        let statuses = [DataDirStatus.mounted, DataDirStatus.pendingMount, DataDirStatus.volumeMissing,
                        DataDirStatus.local, DataDirStatus.linked, DataDirStatus.existingSymlink,
                        DataDirStatus.needsNormalization]
        let items = statuses.enumerated().map { index, status in
            var entry = item("/Data/entry-\(index)")
            entry.status = status
            return entry
        }

        let rows = DataDirTree.rows(in: DataDirTree.summaryTree(from: items, filter: .mounted))

        XCTAssertEqual(rows.map(\.item.status), Array(statuses.prefix(3)))
    }

    func testLinkedSummaryDoesNotIncludeUnmanagedSymlinks() {
        var linked = item("/Data/linked")
        linked.status = DataDirStatus.linked
        var existing = item("/Data/existing")
        existing.status = DataDirStatus.existingSymlink

        let rows = DataDirTree.rows(in: DataDirTree.summaryTree(from: [linked, existing], filter: .linked))

        XCTAssertEqual(rows.map(\.id), [linked.id])
    }

    func testExistingSymlinkSummaryExcludesPersonalDirectoryEntries() {
        var personal = item("/Users/example/Library/Containers/com.example.app/Data/Downloads")
        personal.status = DataDirStatus.existingSymlink
        personal.linkedDestination = URL(fileURLWithPath: "/Users/example/Downloads")
        var existing = item("/Users/example/Library/Containers/com.example.app/Data/Documents/files")
        existing.status = DataDirStatus.existingSymlink
        existing.linkedDestination = URL(fileURLWithPath: "/Volumes/External/files")

        XCTAssertTrue(personal.isUserDirectoryLink)
        let rows = DataDirTree.rows(in: DataDirTree.summaryTree(from: [personal, existing], filter: .existingSymlink))

        XCTAssertEqual(rows.map(\.id), [existing.id])
    }

    func testSummaryTreeRemovesUnmatchedChildrenAlreadyStoredInInput() {
        var mounted = item("/Data/mounted")
        mounted.status = DataDirStatus.mounted
        mounted.children = [item("/Data/mounted/local")]

        let rows = DataDirTree.rows(in: DataDirTree.summaryTree(from: [mounted], filter: .mounted))

        XCTAssertEqual(rows.map(\.id), [mounted.id])
        XCTAssertTrue(DataDirTree.summaryTree(from: [item("/Data/local")], filter: .mounted).isEmpty)
    }

    func testDataRowAlwaysShowsContainerIdentity() {
        let root = item("/Library/Containers/com.example.app")
        let data = item("/Library/Containers/com.example.app/Data")
        let rows = DataDirTree.rows(in: DataDirTree.build(from: [root, data]))
        XCTAssertEqual(rows[1].contextPath, "/Library/Containers/com.example.app")
        let promoted = DataDirTree.rows(in: DataDirTree.build(from: [data]))
        XCTAssertEqual(promoted[0].contextPath, "/Library/Containers/com.example.app")
    }

    func testNearestAncestorOwnsEachDirectoryEvenWhenChildrenArriveFirst() {
        let account = item("/Containers/wechat/Data/Documents/xwechat_files/account")
        let documents = item("/Containers/wechat/Data/Documents")
        let files = item("/Containers/wechat/Data/Documents/xwechat_files")
        let backup = item("/Containers/wechat/Data/Documents/xwechat_files/Backup")

        let tree = DataDirTree.build(from: [account, documents, backup, files])

        XCTAssertEqual(tree.map(\.id), [documents.id])
        XCTAssertEqual(tree.first?.children.map(\.id), [files.id])
        XCTAssertEqual(tree.first?.children.first?.children.map(\.id), [account.id, backup.id])
        XCTAssertEqual(DataDirTree.rows(in: tree).map(\.level), [0, 1, 2, 2])
    }

    func testTreePreservesSortedSiblingOrderAcrossDifferentPathDepths() {
        let large = item("/Library/Containers/wechat/Data/Documents")
        let small = item("/Library/Containers/other")
        let child = item("/Library/Containers/wechat/Data/Documents/files")

        let tree = DataDirTree.build(from: [child, large, small])

        XCTAssertEqual(tree.map(\.id), [large.id, small.id])
        XCTAssertEqual(tree.first?.children.map(\.id), [child.id])
    }

    func testSimilarPathPrefixesDoNotCreateFalseAncestors() {
        let files = item("/Data/files")
        let backup = item("/Data/files_backup/account")

        let tree = DataDirTree.build(from: [files, backup])

        XCTAssertEqual(tree.count, 2)
        XCTAssertTrue(tree.allSatisfy(\.isLeaf))
    }

    func testFilteringKeepsAncestorsButRemovesUnrelatedSiblings() {
        let documents = item("/Data/Documents")
        let files = item("/Data/Documents/xwechat_files")
        let match = item("/Data/Documents/xwechat_files/account")
        let other = item("/Data/Documents/xwechat_files/Backup")
        let tree = DataDirTree.build(from: [documents, files, match, other])

        let filtered = DataDirTree.retainingMatches(in: tree, matchingIDs: [match.id])

        XCTAssertEqual(DataDirTree.rows(in: filtered).map(\.id), [documents.id, files.id, match.id])
        XCTAssertTrue(DataDirTree.retainingMatches(in: tree, matchingIDs: []).isEmpty)
    }

    func testCollapsingBranchHidesItsDescendantsAndKeepsOtherRoots() {
        let documents = item("/Data/Documents")
        let files = item("/Data/Documents/xwechat_files")
        let account = item("/Data/Documents/xwechat_files/account")
        let caches = item("/Data/Library/Caches")
        let tree = DataDirTree.build(from: [documents, files, account, caches])

        let rows = DataDirTree.rows(in: tree, collapsedIDs: [files.id])

        XCTAssertEqual(rows.map(\.id), [documents.id, files.id, caches.id])
        XCTAssertEqual(rows[1].parentID, documents.id)
        XCTAssertNil(rows[2].parentID)
    }

    func testDuplicatePathsAppearOnlyOnce() {
        let documents = item("/Data/Documents")
        let child = item("/Data/Documents/files")
        let rows = DataDirTree.rows(in: DataDirTree.build(from: [documents, child, documents, child]))

        XCTAssertEqual(rows.map(\.id), [documents.id, child.id])
    }

    func testContextPathShowsOnlyUnrepresentedIntermediateFolders() {
        let root = item("/Containers/wechat")
        let documents = item("/Containers/wechat/Data/Documents")
        let files = item("/Containers/wechat/Data/Documents/files")
        let rows = DataDirTree.rows(in: DataDirTree.build(from: [root, documents, files]))

        XCTAssertEqual(rows[1].contextPath, "Data")
        XCTAssertNil(rows[2].contextPath)
    }

    func testVisibilityCombinationsRemoveLockedRowsAndKeepManagedOrUnreadableItems() {
        var root = item("/Data")
        root.isMigratable = false
        root.applySize(DirectorySizeResult(bytes: 0))
        var locked = item("/Data/Locked")
        locked.isMigratable = false
        locked.applySize(DirectorySizeResult(bytes: 0))
        var empty = item("/Data/Empty")
        empty.applySize(DirectorySizeResult(bytes: 0))
        var business = item("/Data/Business")
        business.applySize(DirectorySizeResult(bytes: 128))
        var managed = item("/Data/Managed")
        managed.isMigratable = false
        managed.status = DataDirStatus.needsNormalization
        managed.applySize(DirectorySizeResult(bytes: 0))
        var unreadable = item("/Data/Unreadable")
        unreadable.isMigratable = false
        unreadable.sizeIsIncomplete = true
        let items = [root, locked, empty, business, managed, unreadable]
        for zeros in [false, true] {
            for locks in [false, true] {
                let matches = Set(items.filter { $0.matchesVisibility(showZeroByteDirectories: zeros, showLockedStructure: locks) }.map(\.id))
                let tree = DataDirTree.visibleTree(from: items, showZeroByteDirectories: zeros,
                                                   showLockedStructure: locks, matchingIDs: matches)
                let visible = Set(DataDirTree.rows(in: tree).map(\.id))
                XCTAssertTrue(visible.isSuperset(of: [business.id, managed.id, unreadable.id]))
                XCTAssertEqual(visible.contains(root.id), locks)
                XCTAssertEqual(visible.contains(empty.id), zeros)
                XCTAssertEqual(visible.contains(locked.id), locks)
                // Search preserves only ancestors that survived visibility filtering.
                let explicitMatches = matches.intersection([business.id])
                let explicitTree = DataDirTree.visibleTree(from: items, showZeroByteDirectories: zeros,
                                                           showLockedStructure: locks, matchingIDs: explicitMatches)
                XCTAssertEqual(DataDirTree.rows(in: explicitTree).map(\.id), locks ? [root.id, business.id] : [business.id])
            }
        }
    }

    func testHiddenNestedAncestorsPromoteDescendantsAndPreserveFullContext() {
        var root = item("/Containers/wechat")
        root.isMigratable = false
        var data = item("/Containers/wechat/Data")
        data.isMigratable = false
        var documents = item("/Containers/wechat/Data/Documents")
        documents.isMigratable = false
        let account = item("/Containers/wechat/Data/Documents/xwechat_files/account")
        let items = [root, data, documents, account]
        let tree = DataDirTree.visibleTree(from: items, showZeroByteDirectories: true,
                                          showLockedStructure: false, matchingIDs: Set(items.map(\.id)))
        let rows = DataDirTree.rows(in: tree, collapsedIDs: [root.id, data.id, documents.id])
        XCTAssertEqual(rows.map(\.id), [account.id])
        XCTAssertEqual(rows.first?.level, 0)
        XCTAssertNil(rows.first?.parentID)
        XCTAssertEqual(rows.first?.contextPath, "/Containers/wechat/Data/Documents/xwechat_files")
    }

    func testHiddenIntermediateNodePromotesToNearestVisibleAncestorDuringSearch() {
        let root = item("/Data/business")
        var locked = item("/Data/business/structural")
        locked.isMigratable = false
        let child = item("/Data/business/structural/account")
        let other = item("/Data/unrelated")
        let rows = DataDirTree.rows(in: DataDirTree.visibleTree(
            from: [root, locked, child, other], showZeroByteDirectories: true,
            showLockedStructure: false, matchingIDs: [child.id]))
        XCTAssertEqual(rows.map(\.id), [root.id, child.id])
        XCTAssertEqual(rows.map(\.level), [0, 1])
        XCTAssertEqual(rows.last?.contextPath, "structural")
    }

    func testLockedManagedRecoveryAndConflictRowsRemainAvailableWithStructureHidden() {
        var managed = item("/Data/managed")
        managed.hasManagedLinkRecord = true
        var recovery = item("/Data/recovery")
        recovery.recoveryOperationID = UUID()
        var conflict = item("/Data/conflict")
        conflict.status = DataDirStatus.needsNormalization
        let items = [managed, recovery, conflict].map { item in
            var locked = item
            locked.isMigratable = false
            locked.applySize(DirectorySizeResult(bytes: 0))
            return locked
        }
        let tree = DataDirTree.visibleTree(from: items, showZeroByteDirectories: false,
                                          showLockedStructure: false, matchingIDs: Set(items.map(\.id)))
        XCTAssertEqual(DataDirTree.rows(in: tree).map(\.id), items.map(\.id))
    }

    func testRevealSelectsFirstMatchInDisplayedTreeOrder() throws {
        let root = item("/Data/z-first")
        let first = item("/Data/z-first/target")
        let second = item("/Data/a-second")
        let tree = DataDirTree.build(from: [root, first, second])

        let plan = try XCTUnwrap(DataDirTree.revealPlan(in: tree, matchingIDs: [second.id, first.id]))

        XCTAssertEqual(plan.selectedID, first.id)
    }

    func testRevealExpandsEveryTargetBranchAndOnlyItsGroups() throws {
        let root = item("/Containers/app")
        let parent = item("/Containers/app/Data")
        let first = item("/Containers/app/Data/files")
        let second = item("/Containers/app/Documents")
        let support = item("/Support/app", type: .applicationSupport)
        let third = item("/Support/app/files", type: .applicationSupport)
        let unrelated = item("/Caches/app", type: .caches)
        let tree = DataDirTree.build(from: [root, parent, first, second])
            + DataDirTree.build(from: [support, third]) + [unrelated]

        let plan = try XCTUnwrap(DataDirTree.revealPlan(in: tree, matchingIDs: [first.id, second.id, third.id]))

        XCTAssertEqual(plan.expandedDirectoryIDs, [root.id, parent.id, first.id, second.id, support.id, third.id])
        XCTAssertEqual(plan.expandedGroups, [.containers, .applicationSupport])
        let collapsed = Set(DataDirTree.rows(in: tree).map(\.id)).subtracting(plan.expandedDirectoryIDs)
        let revealedIDs = Set(DataDirTree.rows(in: tree, collapsedIDs: collapsed).map(\.id))
        XCTAssertTrue(revealedIDs.isSuperset(of: [first.id, second.id, third.id]))
    }

    func testRevealDoesNotExpandSimilarPrefixesOrUnrelatedBranches() throws {
        let root = item("/Data/files")
        let target = item("/Data/files/account")
        let prefixSibling = item("/Data/file")
        let unrelated = item("/Data/other")
        let tree = DataDirTree.build(from: [root, target, prefixSibling, unrelated])

        let plan = try XCTUnwrap(DataDirTree.revealPlan(in: tree, matchingIDs: [target.id]))

        XCTAssertEqual(plan.expandedDirectoryIDs, [root.id, target.id])
    }

    func testRevealIgnoresStaleIDsAndReturnsNoPlanWithoutCurrentMatches() throws {
        let current = item("/Data/current")
        let stale = "/Data/removed"

        let plan = try XCTUnwrap(DataDirTree.revealPlan(in: [current], matchingIDs: [current.id, stale]))

        XCTAssertEqual(plan.selectedID, current.id)
        XCTAssertEqual(plan.expandedDirectoryIDs, [current.id])
        XCTAssertNil(DataDirTree.revealPlan(in: [current], matchingIDs: [stale]))
        XCTAssertNil(DataDirTree.revealPlan(in: [current], matchingIDs: []))
    }

    func testRevealFindsPromotedTargetsWithoutRestoringHiddenAncestors() throws {
        let root = item("/Data/app")
        var hidden = item("/Data/app/structure")
        hidden.isMigratable = false
        let target = item("/Data/app/structure/files")
        let tree = DataDirTree.visibleTree(from: [root, hidden, target], showZeroByteDirectories: true,
                                          showLockedStructure: false, matchingIDs: [target.id])

        let plan = try XCTUnwrap(DataDirTree.revealPlan(in: tree, matchingIDs: [target.id]))

        XCTAssertEqual(plan.selectedID, target.id)
        XCTAssertEqual(plan.expandedDirectoryIDs, [root.id, target.id])
        XCTAssertEqual(DataDirTree.rows(in: tree).last?.parentID, root.id)
    }

    func testRepeatedRevealRequestsWithSameTargetsHaveDistinctTokens() {
        let first = DataDirTree.RevealRequest(itemIDs: ["/Data/files"])
        let repeated = DataDirTree.RevealRequest(itemIDs: first.itemIDs)

        XCTAssertEqual(first.itemIDs, repeated.itemIDs)
        XCTAssertNotEqual(first.id, repeated.id)
        XCTAssertNotEqual(first, repeated)
    }

    private func item(_ path: String, type: DataDirType = .containers) -> DataDirItem {
        DataDirItem(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: URL(fileURLWithPath: path),
            type: type,
            priority: .critical,
            description: ""
        )
    }
}
