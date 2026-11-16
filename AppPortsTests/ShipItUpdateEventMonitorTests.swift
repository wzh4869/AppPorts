import Foundation
import XCTest
@testable import AppPorts

final class ShipItUpdateEventMonitorTests: XCTestCase {
    func testAtomicMigrationRecordReplacementTriggersWhileUnrelatedFilesAreIgnored() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShipIt-record-events-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let caches = root.appendingPathComponent("Caches")
        let records = root.appendingPathComponent("Records/search.json")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: records.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: records)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = EventCounter()
        let first = ShipItUpdateEventMonitor(caches: caches, latency: 0.02, watchedFiles: [records]) { count.increment() }
        XCTAssertTrue(first.start(identifiers: []))
        // The newly created watch roots may initially request a state rescan.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let baseline = count.value
        try Data("unrelated".utf8).write(to: records.deletingLastPathComponent().appendingPathComponent("other.json"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(count.value, baseline)
        first.stop()
        let changed = expectation(description: "Migration record replacement")
        changed.assertForOverFulfill = false
        let monitor = ShipItUpdateEventMonitor(caches: caches, latency: 0.02, watchedFiles: [records]) { changed.fulfill() }
        XCTAssertTrue(monitor.start(identifiers: []))
        defer { monitor.stop() }
        try Data("[{}]".utf8).write(to: records, options: .atomic)
        await fulfillment(of: [changed], timeout: 5)
    }

    private final class EventCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testAtomicStateReplacementTriggersAnEvent() async throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ShipIt-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: caches) }
        let cache = caches.appendingPathComponent("org.appports.fixture.ShipIt")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let state = cache.appendingPathComponent("ShipItState.plist")
        try Data("old state".utf8).write(to: state)
        let changed = expectation(description: "Atomic state replacement")
        changed.assertForOverFulfill = false
        let monitor = ShipItUpdateEventMonitor(caches: caches, latency: 0.02) { changed.fulfill() }
        XCTAssertTrue(monitor.start(identifiers: ["org.appports.fixture"]))
        defer { monitor.stop() }
        try Data("new state".utf8).write(to: state, options: .atomic)
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: state), Data("new state".utf8))
    }

    func testChangingIdentifiersAcceptsOnlyTheNewManagedApp() async throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ShipIt-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: caches) }
        let cache = caches.appendingPathComponent("org.appports.new.ShipIt")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let changed = expectation(description: "Newly managed app")
        changed.assertForOverFulfill = false
        let monitor = ShipItUpdateEventMonitor(caches: caches, latency: 0.02) { changed.fulfill() }
        XCTAssertTrue(monitor.start(identifiers: ["org.appports.old"]))
        XCTAssertTrue(monitor.start(identifiers: ["org.appports.new"]))
        defer { monitor.stop() }
        try Data("state".utf8).write(to: cache.appendingPathComponent("ShipItState.plist"))
        await fulfillment(of: [changed], timeout: 5)
    }
}
