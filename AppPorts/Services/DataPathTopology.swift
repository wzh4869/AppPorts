import Foundation

/// Declarative topology, including offline records. No discovery or dictionary deduplication is performed here.
struct DataPathTopology: Sendable {
    enum Origin: String, CaseIterable, Sendable { case mount, link, transfer, retained, mountedPath }
    enum Relationship: String, Sendable { case same, ancestor, descendant, sibling, disjoint }
    struct Entry: Equatable, Sendable {
        let path: String
        let origin: Origin
        var operationID: UUID? = nil
        var volumeUUID: String? = nil
    }
    struct Conflict: Equatable, Sendable {
        let entry: Entry
        let relationship: Relationship
    }
    struct EntryConflict: Equatable, Sendable {
        let first: Entry
        let second: Entry
        let relationship: Relationship
    }
    struct RecoveryExemption: Sendable {
        let operationID: UUID
        let expectedSourceRoot: String
    }

    let entries: [Entry]

    func conflicts(with path: String, exempting exemption: RecoveryExemption? = nil) -> [Conflict] {
        conflicts(with: path, exemptions: exemption.map { [$0] } ?? [])
    }

    func conflicts(with path: String, exemptions: [RecoveryExemption]) -> [Conflict] {
        sortedEntries.compactMap { entry in
            // The requested root and the exempted entry must BOTH be the exact expected root.
            // A child operation never inherits its parent's exemption.
            if exemptions.contains(where: {
                entry.operationID == $0.operationID
                    && Self.relationship(entry.path, $0.expectedSourceRoot) == .same
                    && Self.relationship(path, $0.expectedSourceRoot) == .same
            }) { return nil }
            let relation = Self.relationship(path, entry.path)
            guard Self.overlaps(relation) else { return nil }
            return Conflict(entry: entry, relationship: relation)
        }
    }

    func conflictingEntries() -> [EntryConflict] {
        let ordered = sortedEntries
        var result: [EntryConflict] = []
        for first in ordered.indices {
            for second in ordered.indices where second > first {
                let relation = Self.relationship(ordered[first].path, ordered[second].path)
                if Self.overlaps(relation) {
                    result.append(EntryConflict(first: ordered[first], second: ordered[second], relationship: relation))
                }
            }
        }
        return result
    }

    /// Both lexical roots and existing canonical aliases count; unavailable offline paths keep lexical identity.
    static func relationship(_ lhs: String, _ rhs: String) -> Relationship {
        let left = aliases(lhs)
        let right = aliases(rhs)
        var foundSibling = false
        for a in left {
            for b in right {
                if a == b { return .same }
            }
        }
        for a in left {
            for b in right {
                if b.starts(with: a) { return .ancestor }
                if a.starts(with: b) { return .descendant }
                if a.dropLast() == b.dropLast() { foundSibling = true }
            }
        }
        return foundSibling ? .sibling : .disjoint
    }

    static func overlaps(_ relationship: Relationship) -> Bool {
        [.same, .ancestor, .descendant].contains(relationship)
    }

    private static func aliases(_ path: String) -> [[String]] {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Foundation does not reliably resolve an alias when its final child is absent.
        // Resolve the nearest existing ancestor, then reattach the missing suffix.
        var ancestor = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var canonical = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { canonical.appendPathComponent(component) }
        return [url.pathComponents, canonical.standardizedFileURL.pathComponents]
    }

    private var sortedEntries: [Entry] {
        entries.sorted {
            let lhs = [$0.path, $0.origin.rawValue, $0.volumeUUID ?? "", $0.operationID?.uuidString ?? ""]
            let rhs = [$1.path, $1.origin.rawValue, $1.volumeUUID ?? "", $1.operationID?.uuidString ?? ""]
            return lhs.lexicographicallyPrecedes(rhs)
        }
    }
}
