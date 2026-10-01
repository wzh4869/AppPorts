import Foundation
import Testing
@testable import AppPorts

struct DataPathTopologyTests {
    @Test("Component boundaries distinguish overlap from siblings and similar prefixes")
    func relations() {
        #expect(DataPathTopology.relationship("/fixture/A", "/fixture/A") == .same)
        #expect(DataPathTopology.relationship("/fixture/A", "/fixture/A/B") == .ancestor)
        #expect(DataPathTopology.relationship("/fixture/A/B", "/fixture/A") == .descendant)
        #expect(DataPathTopology.relationship("/fixture/A", "/fixture/A2") == .sibling)
        #expect(DataPathTopology.relationship("/fixture/A/../B", "/fixture/B/child") == .ancestor)
        #expect(DataPathTopology.relationship("/first/A", "/second/B") == .disjoint)
    }

    @Test("All record origins block nested paths in either insertion order", arguments: DataPathTopology.Origin.allCases)
    func originConflicts(origin: DataPathTopology.Origin) {
        let entries = [DataPathTopology.Entry(path: "/fixture/A", origin: origin, volumeUUID: "offline-volume"),
                       DataPathTopology.Entry(path: "/fixture/B", origin: .link)]
        for ordered in [entries, entries.reversed().map { $0 }] {
            let topology = DataPathTopology(entries: ordered)
            #expect(topology.conflicts(with: "/fixture/A/child").count == 1)
            #expect(topology.conflicts(with: "/fixture").count == 2)
            #expect(topology.conflicts(with: "/fixture/A2").isEmpty)
        }
    }

    @Test("Different UUID facts for one path remain visible")
    func duplicateFactsAreNotOverwritten() {
        let topology = DataPathTopology(entries: [
            .init(path: "/fixture/A", origin: .mount, volumeUUID: "ONE"),
            .init(path: "/fixture/A", origin: .mountedPath, volumeUUID: "TWO")])
        #expect(topology.conflicts(with: "/fixture/A").map(\.entry.volumeUUID) == ["ONE", "TWO"])
        #expect(topology.conflictingEntries().count == 1)
    }

    @Test("Recovery exemption applies only to its own exact source entry")
    func narrowRecoveryExemption() {
        let operation = UUID()
        let topology = DataPathTopology(entries: [
            .init(path: "/fixture/A", origin: .transfer, operationID: operation),
            .init(path: "/fixture/A/child", origin: .retained, operationID: operation),
            .init(path: "/fixture/A", origin: .link, operationID: UUID())])
        let conflicts = topology.conflicts(with: "/fixture/A", exempting: .init(operationID: operation, expectedSourceRoot: "/fixture/A"))
        #expect(conflicts.count == 2)
        #expect(conflicts.contains { $0.entry.path == "/fixture/A/child" })
    }

    @Test("An existing symlink alias cannot bypass a recorded parent")
    func recognizesAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Topology-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let topology = DataPathTopology(entries: [.init(path: actual.path, origin: .mount)])
        #expect(topology.conflicts(with: alias.appendingPathComponent("missing-child").path).count == 1)
    }
}
