import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AppPorts

final class FileContentHasherTests: XCTestCase {
    func testCompleteReadsAvoidEOFAndBufferReuseNeverReusesContent() throws {
        var contents = Data(repeating: 0x41, count: 1_048_577)
        var reads = 0
        var observed: Int64 = 0
        let hasher = FileContentHasher { _, target, wanted, offset in
            reads += 1
            let count = min(wanted, contents.count - Int(offset))
            contents.withUnsafeBytes { bytes in
                if count > 0 { target.copyMemory(from: bytes.baseAddress!.advanced(by: Int(offset)), byteCount: count) }
            }
            return count
        }
        func digest() throws -> Data {
            try hasher.digest(fd: -1, byteCount: Int64(contents.count), path: "fixture",
                checkpoint: {}, didRead: { observed += $0 })
        }
        XCTAssertEqual(try digest(), Data(SHA256.hash(data: contents)))
        XCTAssertEqual(reads, 2, "Do not issue a third read solely to discover EOF")
        XCTAssertEqual(observed, Int64(contents.count))
        contents = Data([0x92])
        XCTAssertEqual(try digest(), Data(SHA256.hash(data: contents)))
        XCTAssertEqual(reads, 3)
        contents = Data()
        XCTAssertEqual(try digest(), Data(SHA256.hash(data: contents)))
        XCTAssertEqual(reads, 3, "An empty regular file requires no data read")
    }

    func testInterruptedAndShortReadsStillHashEveryByte() throws {
        let contents = Data((0..<251).map(UInt8.init))
        var calls = 0
        var observed: Int64 = 0
        let hasher = FileContentHasher { _, target, wanted, offset in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            let count = min(7, wanted, contents.count - Int(offset))
            contents.withUnsafeBytes { bytes in
                target.copyMemory(from: bytes.baseAddress!.advanced(by: Int(offset)), byteCount: count)
            }
            return count
        }
        let digest = try hasher.digest(fd: -1, byteCount: Int64(contents.count), path: "fixture",
            checkpoint: {}, didRead: { observed += $0 })
        XCTAssertEqual(digest, Data(SHA256.hash(data: contents)))
        XCTAssertEqual(observed, Int64(contents.count))
    }

    func testPrematureEOFAndIOFailureNeverReturnDigest() throws {
        for failure in [0, -1] {
            let hasher = FileContentHasher { _, _, _, _ in errno = EIO; return failure }
            XCTAssertThrowsError(try hasher.digest(fd: -1, byteCount: 1, path: "fixture",
                checkpoint: {}, didRead: { _ in }))
        }
    }

    func testCancellationStopsBeforeReadingAndAlsoAfterTheLastChunk() throws {
        var reads = 0
        let hasher = FileContentHasher { _, target, wanted, _ in
            reads += 1
            target.initializeMemory(as: UInt8.self, repeating: 0x11, count: wanted)
            return wanted
        }
        XCTAssertThrowsError(try hasher.digest(fd: -1, byteCount: 1, path: "fixture",
            checkpoint: { throw CancellationError() }, didRead: { _ in })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(reads, 0)
        var cancelled = false
        XCTAssertThrowsError(try hasher.digest(fd: -1, byteCount: 1, path: "fixture",
            checkpoint: { if cancelled { throw CancellationError() } },
            didRead: { _ in cancelled = true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(reads, 1)
    }
}
