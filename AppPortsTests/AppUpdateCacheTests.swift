import Darwin
import XCTest
@testable import AppPorts

final class AppUpdateCacheTests: XCTestCase {
    private struct Workspace {
        let root: URL
        let app: URL
        let helper: URL
        let cache: URL
        let cleanup: AppUpdateCache

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsSparkleCache-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            app = root.appendingPathComponent("Applications/Music.app")
            helper = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Resources/Autoupdate.app")
            let caches = root.appendingPathComponent("Caches")
            cache = caches.appendingPathComponent("example.music/org.sparkle-project.Sparkle/Music (Autoupdate).app")
            cleanup = AppUpdateCache(directory: caches)
            try FileManager.default.createDirectory(at: helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.music"], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data("helper executable".utf8).write(to: helper.appendingPathComponent("Contents/MacOS/Autoupdate"))
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        func copyHelper() throws { try FileManager.default.copyItem(at: helper, to: cache) }

        func dispose() {
            // Only this exclusively created test directory is ever unlocked for removal.
            for url in (try? SignatureSnapshot.items(in: root)) ?? [] {
                if let info = try? SignatureSnapshot.info(at: url) {
                    _ = lchflags(url.path, info.st_flags & ~UInt32(UF_IMMUTABLE))
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func lockTree(_ url: URL) throws {
        for entry in try SignatureSnapshot.items(in: url).reversed() {
            let info = try SignatureSnapshot.info(at: entry)
            XCTAssertEqual(lchflags(entry.path, info.st_flags | UInt32(UF_IMMUTABLE)), 0)
        }
    }

    func testFoundationCopyCarriesLocksAndCleanupLetsSparkleReplaceItsHelper() throws {
        let w = try Workspace(); defer { w.dispose() }
        try lockTree(w.helper)
        try w.copyHelper()
        XCTAssertNotEqual(try SignatureSnapshot.info(at: w.cache).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertThrowsError(try FileManager.default.removeItem(at: w.cache))
        let contents = try SignatureSnapshot.fingerprint(of: w.cache)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 1)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: w.cache), contents)
        for url in try SignatureSnapshot.items(in: w.cache) {
            XCTAssertEqual(try SignatureSnapshot.info(at: url).st_flags & UInt32(UF_IMMUTABLE), 0)
        }
        XCTAssertNotEqual(try SignatureSnapshot.info(at: w.helper).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 0)
        try FileManager.default.removeItem(at: w.cache)
        try w.copyHelper()
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: w.cache), contents)
    }

    func testOlderOrDifferentHelperContentsAreUnlockedAndPreserved() throws {
        let w = try Workspace(); defer { w.dispose() }
        try w.copyHelper()
        try Data("independent contents".utf8).write(to: w.cache.appendingPathComponent("Contents/MacOS/Autoupdate"))
        try lockTree(w.cache)
        let before = try SignatureSnapshot.fingerprint(of: w.cache)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 1)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: w.cache), before)
        XCTAssertEqual(try SignatureSnapshot.info(at: w.cache).st_flags & UInt32(UF_IMMUTABLE), 0)
    }

    func testSymlinkedCacheParentCannotRedirectUnlocking() throws {
        let w = try Workspace(); defer { w.dispose() }
        let original = w.cache.deletingLastPathComponent()
        let outside = w.root.appendingPathComponent("Independent")
        try FileManager.default.moveItem(at: original, to: outside)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        try w.copyHelper()
        let real = w.cache.resolvingSymlinksInPath()
        try lockTree(real)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 0)
        XCTAssertNotEqual(try SignatureSnapshot.info(at: real).st_flags & UInt32(UF_IMMUTABLE), 0)
    }

    func testMatchingHardLinkedContentsDoNotAuthorizeChangingTheOutsideFile() throws {
        let w = try Workspace(); defer { w.dispose() }
        try w.copyHelper()
        let executable = w.cache.appendingPathComponent("Contents/MacOS/Autoupdate")
        let outside = w.root.appendingPathComponent("IndependentExecutable")
        try FileManager.default.linkItem(at: executable, to: outside)
        try lockTree(w.cache)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: w.helper), try SignatureSnapshot.fingerprint(of: w.cache))
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 1)
        XCTAssertNotEqual(try SignatureSnapshot.info(at: outside).st_flags & UInt32(UF_IMMUTABLE), 0)
    }

    func testAllApplicationCacheLocksAreClearedWithoutChangingContentsOrOtherApplications() throws {
        let w = try Workspace(); defer { w.dispose() }
        try w.copyHelper()
        let executable = w.cache.appendingPathComponent("Contents/MacOS/Autoupdate")
        XCTAssertEqual(lchflags(executable.path, UInt32(UF_IMMUTABLE | UF_NODUMP)), 0)
        let business = w.cache.deletingLastPathComponent().appendingPathComponent("BusinessData")
        try Data("keep".utf8).write(to: business)
        XCTAssertEqual(lchflags(business.path, UInt32(UF_IMMUTABLE)), 0)
        let independent = w.cleanup.directory.appendingPathComponent("example.other/BusinessData")
        try FileManager.default.createDirectory(at: independent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other application".utf8).write(to: independent)
        XCTAssertEqual(lchflags(independent.path, UInt32(UF_IMMUTABLE)), 0)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 1)
        XCTAssertEqual(try SignatureSnapshot.info(at: executable).st_flags, UInt32(UF_NODUMP))
        XCTAssertEqual(try Data(contentsOf: business), Data("keep".utf8))
        XCTAssertEqual(try SignatureSnapshot.info(at: business).st_flags, 0)
        XCTAssertEqual(try SignatureSnapshot.info(at: independent).st_flags, UInt32(UF_IMMUTABLE))
    }

    func testShipItCacheAndApplicationCacheAreBothUnlocked() throws {
        let w = try Workspace(); defer { w.dispose() }
        try w.copyHelper(); try lockTree(w.cache)
        let shipIt = w.cleanup.directory.appendingPathComponent("example.music.ShipIt")
        try FileManager.default.createDirectory(at: shipIt, withIntermediateDirectories: true)
        let installer = shipIt.appendingPathComponent("Installer")
        try Data("keep installer".utf8).write(to: installer)
        try lockTree(shipIt)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 2)
        XCTAssertEqual(try SignatureSnapshot.info(at: w.cache).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(try SignatureSnapshot.info(at: installer).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(try Data(contentsOf: installer), Data("keep installer".utf8))
    }

    func testAdmissionFailurePreservesContentsAndCanRetryRemainingLocks() throws {
        let w = try Workspace(); defer { w.dispose() }
        try w.copyHelper(); try lockTree(w.cache)
        let before = try SignatureSnapshot.fingerprint(of: w.cache)
        var writes = 0
        XCTAssertThrowsError(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {
            writes += 1
            if writes == 2 { throw POSIXError(.EACCES) }
        }))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: w.cache), before)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 1)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 0)
    }

    func testApplicationCacheIsUnlockedWithoutRequiringTheSameHelperSource() throws {
        let w = try Workspace(); defer { w.dispose() }
        try w.copyHelper(); try lockTree(w.cache)
        let outside = w.root.appendingPathComponent("IndependentHelper.app")
        try FileManager.default.moveItem(at: w.helper, to: outside)
        try FileManager.default.createSymbolicLink(at: w.helper, withDestinationURL: outside)
        XCTAssertEqual(try w.cleanup.unlockCaches(for: w.app, recheckAdmission: {}), 1)
        XCTAssertEqual(try SignatureSnapshot.info(at: w.cache).st_flags & UInt32(UF_IMMUTABLE), 0)
    }
}
