import Foundation
import XCTest
@testable import AppPorts

final class ShipItUpdateEventMonitorTests: XCTestCase {
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
