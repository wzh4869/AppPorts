import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AppPorts

final class DataScanPerformanceTests: XCTestCase {
    func testBatchScanHashesEveryFileAcrossWindowsAndRejectsSameSizeChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var contents: [String: Data] = [:]
        for index in 0..<97 {
            let name = String(format: "file-%03d", index)
            let sizes = [0, 1, 4096, 16385, 1_048_577]
            let data = Data(repeating: UInt8(index), count: sizes[index % sizes.count])
            try data.write(to: root.appendingPathComponent(name))
            contents[name] = data
        }
        let serial = try TreeCopySession.$concurrentScanReads.withValue(1) {
            try TreeCopySession.snapshot(at: root)
        }
        let progress = DataTransferProgress()
        let parallel = try DataTransferSession.$progress.withValue(progress) {
            try TreeCopySession.snapshot(at: root)
        }
        XCTAssertEqual(parallel, serial)
        XCTAssertEqual(progress.snapshot().readBytes, parallel.logicalBytes)
        for entry in parallel.entries where entry.kind == .file {
            XCTAssertEqual(entry.digest, Data(SHA256.hash(data: try XCTUnwrap(contents[entry.path]))))
        }
        let changed = root.appendingPathComponent("file-096")
        let originalTime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: changed.path)[.modificationDate])
        try Data([0xff]).write(to: changed)
        try FileManager.default.setAttributes([.modificationDate: originalTime], ofItemAtPath: changed.path)
        XCTAssertThrowsError(try TreeCopySession.verifyUnchanged(at: root, against: parallel))
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.path))
    }

    /// Opt-in, disposable fixtures only. Run the same test products and dataset
    /// before/after scheduling changes; never infer USB throughput from tmp.
    func testScanBenchmark() throws {
        guard let output = ProcessInfo.processInfo.environment["APPPORTS_SCAN_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Set APPPORTS_SCAN_BENCHMARK_OUTPUT for an isolated scan benchmark")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [[String: Any]] = []
        for dataset in ["small", "mixed", "large"] {
            let directory = root.appendingPathComponent(dataset)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let count = dataset == "large" ? 16 : 4096
            for index in 0..<count {
                let size: Int
                if dataset == "large" { size = 32 * 1024 * 1024 }
                else if dataset == "mixed", index % 64 == 0 { size = 2 * 1024 * 1024 + index }
                else { size = 4096 + index % 97 }
                try Data(repeating: UInt8(index % 251), count: size)
                    .write(to: directory.appendingPathComponent(String(format: "%05d", index)))
            }
            let baseline = try TreeCopySession.snapshot(at: directory)
            for round in 0..<4 {
                let session = DataTransferSession()
                let start = ProcessInfo.processInfo.systemUptime
                let actual = try DataTransferSession.$current.withValue(session) {
                    try TreeCopySession.snapshot(at: directory)
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                XCTAssertEqual(actual, baseline)
                XCTAssertEqual(session.measurements["hashReadBytes"], Double(baseline.logicalBytes))
                results.append(["dataset": dataset, "round": round, "seconds": elapsed,
                    "entries": actual.entries.count, "bytes": actual.logicalBytes])
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
