import XCTest
@testable import AppPorts

final class DataDirTreeTests: XCTestCase {
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

    func testVisibilityCombinationsKeepContextAndManagedOrUnreadableItems() {
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
                let tree = DataDirTree.retainingMatches(in: DataDirTree.build(from: items), matchingIDs: matches)
                let visible = Set(DataDirTree.rows(in: tree).map(\.id))
                XCTAssertTrue(visible.isSuperset(of: [root.id, business.id, managed.id, unreadable.id]))
                XCTAssertEqual(visible.contains(empty.id), zeros)
                XCTAssertEqual(visible.contains(locked.id), locks)
                // Explicit search/status/type predicates still narrow matching IDs before retention.
                let explicitMatches = matches.intersection([business.id])
                let explicitTree = DataDirTree.retainingMatches(in: DataDirTree.build(from: items), matchingIDs: explicitMatches)
                XCTAssertEqual(DataDirTree.rows(in: explicitTree).map(\.id), [root.id, business.id])
            }
        }
    }

    private func item(_ path: String) -> DataDirItem {
        DataDirItem(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: URL(fileURLWithPath: path),
            type: .containers,
            priority: .critical,
            description: ""
        )
    }
}
