import XCTest
@testable import AppPorts

final class ExistingLinkResetTests: XCTestCase {
    private let fm = FileManager.default

    private func withWorkspace(_ operation: (URL, URL, DataDirMover) async throws -> Void) async throws {
        try await withStoreWorkspace { home, external, mover, _ in
            try await operation(home, external, mover)
        }
    }

    private func withStoreWorkspace(_ operation: (URL, URL, DataDirMover, ContainerMountStore) async throws -> Void) async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("ExistingLinkReset-\(UUID())")
        let home = root.appendingPathComponent("Home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("store.plist"))
        try await operation(home, root.appendingPathComponent("External"), DataDirMover(homeDir: home, store: store), store)
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

    func testResetArchivesOldTransferAndReleasesItsReservation() async throws {
        try await withStoreWorkspace { home, external, mover, store in
            try fm.createDirectory(at: external, withIntermediateDirectories: false)
            let payload = external.appendingPathComponent("payload")
            try Data("keep".utf8).write(to: payload)
            let local = home.appendingPathComponent(".bun")
            let backup = home.appendingPathComponent(".old-bun-copy")
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            try Data("backup".utf8).write(to: backup.appendingPathComponent("payload"))
            try fm.createSymbolicLink(at: local, withDestinationURL: external)
            let transfer = DataTransferRecord(mode: .symlink, direction: .migrate,
                appName: "Bun", dataDirType: DataDirType.dotFolder.rawValue,
                originalPath: local.path, activePath: local.path, destinationPath: external.path,
                backupPath: backup.path, sourceIdentity: try DataPathIdentity.capture(local))
            try store.beginTransfer(transfer)
            XCTAssertThrowsError(try DataOperationSafety(homeDirectory: home, store: store).requireNoOverlap(at: local))

            try await mover.resetExistingLink(item: item(local), expectedDestination: external)

            XCTAssertEqual(try fm.contentsOfDirectory(atPath: local.path), [])
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "keep")
            XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("payload"), encoding: .utf8), "backup")
            XCTAssertTrue(try store.transfers().isEmpty)
            let materials = try store.preservedMaterials()
            XCTAssertEqual(materials.count, 1)
            XCTAssertEqual(materials.first?.recoveryRecord, transfer)
            XCTAssertTrue(materials.first?.paths.contains(backup.path) == true)
            XCTAssertNoThrow(try DataOperationSafety(homeDirectory: home, store: store).requireNoOverlap(at: local))
        }
    }

    func testResetArchivesOfflineManagedIndexWithoutReadingItsTarget() async throws {
        try await withStoreWorkspace { home, external, mover, store in
            let local = home.appendingPathComponent(".bun")
            try fm.createSymbolicLink(at: local, withDestinationURL: external)
            let link = ManagedDataLinkRecord(operationID: UUID(), originalPath: local.path,
                destinationPath: external.path, destinationIdentity: DataPathIdentity(device: 1, inode: 123),
                appName: "Bun", dataDirType: DataDirType.dotFolder.rawValue)
            try store.upsertManagedLink(link)

            try await mover.resetExistingLink(item: item(local), expectedDestination: external)

            XCTAssertEqual(try fm.contentsOfDirectory(atPath: local.path), [])
            XCTAssertFalse(fm.fileExists(atPath: external.path))
            XCTAssertTrue(try store.managedLinks().isEmpty)
            XCTAssertEqual(try store.preservedMaterials().first?.paths, [external.path])
            XCTAssertNoThrow(try DataOperationSafety(homeDirectory: home, store: store).requireNoOverlap(at: local))
        }
    }

    func testResetKeepsUnrelatedAncestorTransferAndItsLink() async throws {
        try await withStoreWorkspace { home, external, mover, store in
            let parent = home.appendingPathComponent("Tools")
            try fm.createDirectory(at: parent, withIntermediateDirectories: false)
            let local = parent.appendingPathComponent(".bun")
            try fm.createSymbolicLink(at: local, withDestinationURL: external)
            let transfer = DataTransferRecord(mode: .symlink, direction: .migrate,
                appName: "Tools", dataDirType: DataDirType.custom.rawValue,
                originalPath: parent.path, activePath: parent.path,
                destinationPath: home.deletingLastPathComponent().appendingPathComponent("Other").path,
                sourceIdentity: try DataPathIdentity.capture(parent))
            try store.beginTransfer(transfer)

            do {
                try await mover.resetExistingLink(item: item(local), expectedDestination: external)
                XCTFail("An unrelated ancestor reservation must still block reset")
            } catch {}

            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: local.path), external.path)
            XCTAssertEqual(try store.transfers(), [transfer])
            XCTAssertTrue(try store.preservedMaterials().isEmpty)
        }
    }
}
