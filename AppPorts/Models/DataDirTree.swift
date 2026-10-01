import Foundation

/// Presentation-only hierarchy. Input order is preserved within each sibling list.
enum DataDirTree {
    struct Row: Identifiable {
        let item: DataDirItem
        let level: Int
        let parentID: String?

        var id: String { item.id }

        /// Only show the part of the parent path that the indentation does not explain.
        var contextPath: String? {
            let parentPath = item.path.standardizedFileURL.deletingLastPathComponent().path
            if let parentID {
                guard parentPath != parentID else { return nil }
                return String(parentPath.dropFirst(parentID.count + 1))
            }
            let home = NSHomeDirectory()
            return parentPath.hasPrefix(home + "/")
                ? "~" + parentPath.dropFirst(home.count)
                : parentPath
        }
    }

    static func build(from items: [DataDirItem]) -> [DataDirItem] {
        var seen = Set<String>()
        let uniqueItems = items.filter { seen.insert($0.id).inserted }
        let paths = Set(uniqueItems.map(\.id))
        var roots: [DataDirItem] = []
        var children: [String: [DataDirItem]] = [:]

        for item in uniqueItems {
            var ancestor = item.path.standardizedFileURL.deletingLastPathComponent()
            var parentID: String?
            while ancestor.path != item.id {
                if paths.contains(ancestor.path) {
                    parentID = ancestor.path
                    break
                }
                guard ancestor.path != "/" else { break }
                ancestor.deleteLastPathComponent()
            }
            if let parentID {
                children[parentID, default: []].append(item)
            } else {
                roots.append(item)
            }
        }

        func populate(_ item: DataDirItem) -> DataDirItem {
            var result = item
            result.children = (children[item.id] ?? []).map(populate)
            return result
        }
        return roots.map(populate)
    }

    /// Visibility removes rows, while search may keep context only among those visible rows.
    /// Rebuilding after visibility filtering promotes descendants across hidden ancestors;
    /// Row.contextPath supplies the intermediate path that indentation no longer represents.
    static func visibleTree(from items: [DataDirItem], showZeroByteDirectories: Bool,
                            showLockedStructure: Bool, matchingIDs: Set<String>) -> [DataDirItem] {
        let visibleItems = items.filter {
            $0.matchesVisibility(showZeroByteDirectories: showZeroByteDirectories,
                                 showLockedStructure: showLockedStructure)
        }
        return retainingMatches(in: build(from: visibleItems), matchingIDs: matchingIDs)
    }

    /// Keep ancestors of matches so a search never hides the directory's context.
    static func retainingMatches(in items: [DataDirItem], matchingIDs: Set<String>) -> [DataDirItem] {
        items.compactMap { item in
            var result = item
            result.children = retainingMatches(in: item.children, matchingIDs: matchingIDs)
            return matchingIDs.contains(item.id) || !result.children.isEmpty ? result : nil
        }
    }

    static func rows(in items: [DataDirItem], collapsedIDs: Set<String> = []) -> [Row] {
        func visit(_ items: [DataDirItem], level: Int, parentID: String?) -> [Row] {
            items.flatMap { item in
                let row = Row(item: item, level: level, parentID: parentID)
                return [row] + (collapsedIDs.contains(item.id)
                    ? []
                    : visit(item.children, level: level + 1, parentID: item.id))
            }
        }
        return visit(items, level: 0, parentID: nil)
    }
}
