import Darwin
import Foundation
import XCTest
@testable import AppPorts

final class AppScannerProcessWaitTests: XCTestCase {
    func testExitedChildrenAreObservedOnTheirLaunchingTaskThread() async throws {
        var failures: [Int] = []
        for attempt in 0..<30 {
            let finished = try await Task.detached { () throws -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = ["0.01"]
                try process.run()
                let finished = process.waitUntilExit(withTimeout: 0.3)
                // Same-thread wait also reaps children from the old broken helper.
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
                return finished
            }.value
            if !finished { failures.append(attempt) }
        }
        XCTAssertTrue(failures.isEmpty, "Exited children falsely timed out: \(failures)")
    }

    func testRealDeadlineTerminatesAndReapsAnUnresponsiveChild() async throws {
        let result = try await Task.detached { () throws -> (Bool, Bool, TimeInterval) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 3"]
            try process.run()
            defer {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            let started = Date()
            let finished = process.waitUntilExit(withTimeout: 0.1)
            return (finished, process.isRunning, Date().timeIntervalSince(started))
        }.value
        XCTAssertFalse(result.0)
        XCTAssertFalse(result.1, "Timed-out child must be terminated and reaped before returning")
        XCTAssertLessThan(result.2, 1, "Ignoring SIGTERM must not turn the deadline into an unbounded wait")
    }

    func testNormalExitKeepsItsOriginalStatus() async throws {
        for status in [0, 23] {
            let result = try await Task.detached { () throws -> (Bool, Int32) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "exit \(status)"]
                try process.run()
                let finished = process.waitUntilExit(withTimeout: 1)
                return (finished, process.terminationStatus)
            }.value
            XCTAssertTrue(result.0)
            XCTAssertEqual(result.1, Int32(status))
        }
    }
}
