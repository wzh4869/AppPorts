import XCTest
@testable import AppPorts

final class ExistingLinkResetTests: XCTestCase {
    private let fm = FileManager.default

    private func withWorkspace(_ operation: (URL, URL, DataDirMover) async throws -> Void) async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("ExistingLinkReset-\(UUID())")
        let home = root.appendingPathComponent("Home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("store.plist"))
        try await operation(home, root.appendingPathComponent("External"), DataDirMover(homeDir: home, store: store))
    }

    private func item(_ path: URL) -> DataDirItem {
        DataDirItem(name: "Cache", path: path, type: .dotFolder, priority: .optional, description: "")
    }

    func testResetPreservesExternalDataAndCreatesEmptyLocalDirectory() async throws {
        try await withWorkspace { home, external, mover in
            try fm.createDirectory(at: external, withIntermediateDirectories: false)
            let payload = external.appendingPathComponent("payload")
            try Data("keep".utf8).write(to: payload)
            let local = home.appendingPathComponent(".gradle")
            try fm.createSymbolicLink(at: local, withDestinationURL: external)
            try await mover.resetExistingLink(item: item(local), expectedDestination: external)
            XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: local.path))
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: local.path), [])
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "keep")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: home.path), [".gradle"])
        }
    }

    func testResetBrokenRelativeLinkWithoutExternalDirectory() async throws {
        try await withWorkspace { home, external, mover in
            let local = home.appendingPathComponent(".gradle")
            try fm.createSymbolicLink(atPath: local.path, withDestinationPath: "../External")
            try await mover.resetExistingLink(item: item(local), expectedDestination: external)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: local.path), [])
            XCTAssertFalse(fm.fileExists(atPath: external.path))
        }
    }

    func testResetRejectsOrdinaryDirectoryAndChangedTarget() async throws {
        try await withWorkspace { home, external, mover in
            let local = home.appendingPathComponent(".gradle")
            try fm.createDirectory(at: local, withIntermediateDirectories: false)
            let payload = local.appendingPathComponent("payload")
            try Data("keep".utf8).write(to: payload)
            do {
                try await mover.resetExistingLink(item: item(local), expectedDestination: external)
                XCTFail("Ordinary directory must be rejected")
            } catch {}
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "keep")
            let link = home.appendingPathComponent(".m2")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../Changed")
            do {
                try await mover.resetExistingLink(item: item(link), expectedDestination: external)
                XCTFail("Changed target must be rejected")
            } catch {}
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "../Changed")
        }
    }

    func testResetRejectsLinkInsideSymlinkedParent() async throws {
        try await withWorkspace { home, external, mover in
            try fm.createDirectory(at: external, withIntermediateDirectories: false)
            let parent = home.appendingPathComponent("Parent")
            try fm.createSymbolicLink(at: parent, withDestinationURL: external)
            let local = parent.appendingPathComponent(".gradle")
            try fm.createSymbolicLink(atPath: local.path, withDestinationPath: "/missing-data")
            do {
                try await mover.resetExistingLink(item: item(local), expectedDestination: URL(fileURLWithPath: "/missing-data"))
                XCTFail("Symlinked parent must be rejected")
            } catch {}
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: local.path), "/missing-data")
        }
    }
}
