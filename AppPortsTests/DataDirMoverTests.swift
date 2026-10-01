import Darwin
import XCTest
@testable import AppPorts

final class DataDirMoverTests: XCTestCase {
    private let fileManager = FileManager.default
    private var originalLogEnabledValue: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLogEnabledValue = UserDefaults.standard.object(forKey: "LogEnabled")
        UserDefaults.standard.set(false, forKey: "LogEnabled")
    }

    override func tearDownWithError() throws {
        if let originalLogEnabledValue {
            UserDefaults.standard.set(originalLogEnabledValue, forKey: "LogEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "LogEnabled")
        }

        try super.tearDownWithError()
    }

    func testMigrateAndRestoreRoundTripForApplicationSupportDirectory() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.focus")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("Library/Application Support")
        let externalDataURL = externalBaseURL.appendingPathComponent(localDataURL.lastPathComponent)

        try createDirectoryWithPayload(at: localDataURL, payload: "focus-state")

        let item = DataDirItem(
            name: "Focus",
            path: localDataURL,
            type: .applicationSupport,
            priority: .critical,
            description: "Test payload",
            isMigratable: true
        )

        let mover = makeMover(homeDir: workspace.homeURL)
        try await mover.migrate(item: item, to: externalBaseURL, progressHandler: nil)

        try assertSymlink(localDataURL, pointsTo: externalDataURL)
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL(for: externalDataURL).path))
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "focus-state")

        try await mover.restore(
            item: DataDirItem(
                name: item.name,
                path: localDataURL,
                type: item.type,
                priority: item.priority,
                description: item.description,
                status: "已链接",
                isMigratable: true
            ),
            progressHandler: nil
        )

        try assertRealDirectory(localDataURL)
        XCTAssertEqual(try String(contentsOf: localDataURL.appendingPathComponent("payload.txt")), "focus-state")
        XCTAssertTrue(fileManager.fileExists(atPath: externalDataURL.path))
    }

    func testMigrateRollsBackWhenSymlinkCreationFails() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Caches/com.example.rollback")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("Library/Caches")
        let externalDataURL = externalBaseURL.appendingPathComponent(localDataURL.lastPathComponent)

        try createDirectoryWithPayload(at: localDataURL, payload: "rollback-safe")

        let item = DataDirItem(
            name: "Rollback",
            path: localDataURL,
            type: .caches,
            priority: .optional,
            description: "Test payload",
            isMigratable: true
        )

        let mover = makeMover(homeDir: workspace.homeURL, failSymlinkCreation: true)

        do {
            try await mover.migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("Expected migrate to fail when symlink creation is forced to fail")
        } catch let error as DataDirError {
            guard case .symlinkFailed = error else {
                return XCTFail("Expected symlinkFailed, got \(error)")
            }
        }

        try assertRealDirectory(localDataURL)
        XCTAssertEqual(try String(contentsOf: localDataURL.appendingPathComponent("payload.txt")), "rollback-safe")
        try assertRealDirectory(externalDataURL)
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "rollback-safe")
    }

    func testRetryAfterLinkFailurePreservesNewLocalDataAndTheExternalCopy() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localDataURL = workspace.homeURL.appendingPathComponent("Library/Caches/com.example.retry")
        let externalBaseURL = workspace.externalRootURL.appendingPathComponent("Library/Caches")
        let externalDataURL = externalBaseURL.appendingPathComponent(localDataURL.lastPathComponent)
        try createDirectoryWithPayload(at: localDataURL, payload: "before-link-failure")
        let item = DataDirItem(name: "Retry", path: localDataURL, type: .caches,
                               priority: .optional, description: "Retry after a failed link")

        do {
            try await makeMover(homeDir: workspace.homeURL, failSymlinkCreation: true)
                .migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("The initial link creation must fail")
        } catch let error as DataDirError {
            guard case .symlinkFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }

        try assertRealDirectory(localDataURL)
        try assertRealDirectory(externalDataURL)
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL(for: externalDataURL).path))
        try createDirectoryWithPayload(at: localDataURL, payload: "updated-after-failure")
        let newFileURL = localDataURL.appendingPathComponent("new-after-failure.txt")
        try Data("only-local-copy".utf8).write(to: newFileURL)

        do {
            try await makeMover(homeDir: workspace.homeURL)
                .migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("Matching metadata cannot make the stale external copy authoritative")
        } catch let error as DataDirError {
            guard case .destinationExists = error else { return XCTFail("Unexpected error: \(error)") }
        }

        try assertRealDirectory(localDataURL)
        try assertRealDirectory(externalDataURL)
        XCTAssertEqual(try String(contentsOf: localDataURL.appendingPathComponent("payload.txt")), "updated-after-failure")
        XCTAssertEqual(try Data(contentsOf: newFileURL), Data("only-local-copy".utf8))
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "before-link-failure")
        XCTAssertFalse(fileManager.fileExists(atPath: externalDataURL.appendingPathComponent("new-after-failure.txt").path))
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: localDataURL.deletingLastPathComponent().path)
            .contains { $0.hasPrefix(".appports-migration-backup-") })
    }

    func testMigrateKeepsExternalCopyWhenLocalBackupCleanupFails() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Caches/com.example.backup-cleanup")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("Library/Caches")
        let externalDataURL = externalBaseURL.appendingPathComponent(localDataURL.lastPathComponent)

        try createDirectoryWithPayload(at: localDataURL, payload: "backup-cleanup-safe")

        let item = DataDirItem(
            name: "BackupCleanup",
            path: localDataURL,
            type: .caches,
            priority: .optional,
            description: "Backup cleanup failure fixture",
            isMigratable: true
        )

        let mover = makeMover(homeDir: workspace.homeURL, failSourceBackupCleanup: true)
        try await mover.migrate(item: item, to: externalBaseURL, progressHandler: nil)

        try assertSymlink(localDataURL, pointsTo: externalDataURL)
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "backup-cleanup-safe")

        let parentContents = try fileManager.contentsOfDirectory(atPath: localDataURL.deletingLastPathComponent().path)
        XCTAssertTrue(parentContents.contains { $0.contains(".appports-migration-backup-") })
    }

    func testMigrateRecordsRecoveryWhenUnreadableCopyFails() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.permission")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("Library/Containers")
        let externalDataURL = externalBaseURL.appendingPathComponent(localDataURL.lastPathComponent)
        let unreadableFileURL = localDataURL.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")

        try fileManager.createDirectory(at: localDataURL, withIntermediateDirectories: true)
        try "ok".write(
            to: localDataURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "blocked".write(
            to: unreadableFileURL,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableFileURL.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableFileURL.path) }

        let item = DataDirItem(
            name: "PermissionDenied",
            path: localDataURL,
            type: .containers,
            priority: .critical,
            description: "Permission failure fixture",
            isMigratable: true
        )

        let mover = makeMover(homeDir: workspace.homeURL)

        do {
            try await mover.migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("Expected migrate to fail when source copy encounters an unreadable file")
        } catch let error as DataDirError {
            guard case .copyFailed = error else {
                return XCTFail("Expected copyFailed, got \(error)")
            }
        }

        try assertRealDirectory(localDataURL)
        XCTAssertTrue(fileManager.fileExists(atPath: localDataURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: externalDataURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: externalBaseURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: workspace.externalRootURL.path))
    }

    func testMigrateRejectsExistingRealDestinationWithoutMatchingMetadata() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.conflict")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("Library/Application Support")
        let externalDataURL = externalBaseURL.appendingPathComponent(localDataURL.lastPathComponent)

        try createDirectoryWithPayload(at: localDataURL, payload: "local-real-data")
        try createDirectoryWithPayload(at: externalDataURL, payload: "external-real-data")

        let item = DataDirItem(
            name: "Conflict",
            path: localDataURL,
            type: .applicationSupport,
            priority: .critical,
            description: "Real destination conflict",
            isMigratable: true
        )

        do {
            try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("Expected existing real destination without metadata to be rejected")
        } catch let error as DataDirError {
            guard case .destinationExists = error else {
                return XCTFail("Expected destinationExists, got \(error)")
            }
        }

        try assertRealDirectory(localDataURL)
        try assertRealDirectory(externalDataURL)
        XCTAssertEqual(try String(contentsOf: localDataURL.appendingPathComponent("payload.txt")), "local-real-data")
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "external-real-data")
    }

    func testMigrateRejectsExistingDestinationWithMismatchedMetadata() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Caches/com.example.mismatch")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("Library/Caches")
        let externalDataURL = externalBaseURL.appendingPathComponent(localDataURL.lastPathComponent)

        try createDirectoryWithPayload(at: localDataURL, payload: "local-cache")
        try createDirectoryWithPayload(at: externalDataURL, payload: "external-cache")
        try writeManagedLinkMetadata(
            in: externalDataURL,
            sourcePath: localDataURL,
            destinationPath: externalDataURL,
            type: .applicationSupport
        )

        let item = DataDirItem(
            name: "Mismatch",
            path: localDataURL,
            type: .caches,
            priority: .optional,
            description: "Metadata mismatch",
            isMigratable: true
        )

        do {
            try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("Expected mismatched metadata to be rejected")
        } catch let error as DataDirError {
            guard case .destinationExists = error else {
                return XCTFail("Expected destinationExists, got \(error)")
            }
        }

        try assertRealDirectory(localDataURL)
        try assertRealDirectory(externalDataURL)
        XCTAssertEqual(try String(contentsOf: localDataURL.appendingPathComponent("payload.txt")), "local-cache")
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "external-cache")
    }

    func testMigrateRejectsExistingDestinationEvenWithMatchingMetadata() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Preferences/com.example.recover")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("Library/Preferences")
        let externalDataURL = externalBaseURL.appendingPathComponent(localDataURL.lastPathComponent)

        try createDirectoryWithPayload(at: localDataURL, payload: "local-preferences")
        try createDirectoryWithPayload(at: externalDataURL, payload: "external-preferences")
        try writeManagedLinkMetadata(
            in: externalDataURL,
            sourcePath: localDataURL,
            destinationPath: externalDataURL,
            type: .preferences
        )

        let item = DataDirItem(
            name: "Recover",
            path: localDataURL,
            type: .preferences,
            priority: .recommended,
            description: "Matching metadata does not establish equal contents",
            isMigratable: true
        )

        do {
            try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("A managed destination must not replace a different real source")
        } catch let error as DataDirError {
            guard case .destinationExists = error else { return XCTFail("Unexpected error: \(error)") }
        }

        try assertRealDirectory(localDataURL)
        try assertRealDirectory(externalDataURL)
        XCTAssertEqual(try String(contentsOf: localDataURL.appendingPathComponent("payload.txt")), "local-preferences")
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "external-preferences")
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL(for: externalDataURL).path))
    }

    func testNormalizeManagedLinkMovesDataToNormalizedDestination() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.normalize")
        let currentExternalURL = workspace.rootURL
            .appendingPathComponent("ManualStore/com.example.normalize")
        let normalizedExternalURL = workspace.externalRootURL
            .appendingPathComponent("Library/Application Support/com.example.normalize")

        try createDirectoryWithPayload(at: currentExternalURL, payload: "normalized")

        let mover = makeMover(homeDir: workspace.homeURL)
        try await mover.createLink(localPath: localDataURL, externalPath: currentExternalURL)

        try await mover.normalizeManagedLink(
            localPath: localDataURL,
            currentExternalPath: currentExternalURL,
            normalizedExternalPath: normalizedExternalURL
        )

        try assertSymlink(localDataURL, pointsTo: normalizedExternalURL)
        XCTAssertTrue(fileManager.fileExists(atPath: currentExternalURL.path))
        XCTAssertEqual(try String(contentsOf: normalizedExternalURL.appendingPathComponent("payload.txt")), "normalized")
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL(for: normalizedExternalURL).path))
    }

    func testDeleteLinkRemovesLocalSymlinkAndKeepsExternalDirectory() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Projects/develop")
        let externalDataURL = workspace.externalRootURL
            .appendingPathComponent("Projects/develop")

        try createDirectoryWithPayload(at: externalDataURL, payload: "external-source")

        let mover = makeMover(homeDir: workspace.homeURL)
        try await mover.createLink(localPath: localDataURL, externalPath: externalDataURL)

        try await mover.deleteLink(localPath: localDataURL)

        XCTAssertFalse(fileManager.fileExists(atPath: localDataURL.path))
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "external-source")
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL(for: externalDataURL).path))
    }

    func testMigrateRejectsGroupContainerRootDirectory() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localGroupContainerURL = workspace.homeURL
            .appendingPathComponent("Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("Group Containers")
        let externalGroupContainerURL = externalBaseURL.appendingPathComponent(localGroupContainerURL.lastPathComponent)

        try createDirectoryWithPayload(at: localGroupContainerURL, payload: "group-state")

        let item = DataDirItem(
            name: "GroupContainer",
            path: localGroupContainerURL,
            type: .groupContainers,
            priority: .recommended,
            description: "Protected group container root",
            isMigratable: true
        )

        do {
            try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("Expected group container root migration to be rejected")
        } catch let error as DataDirError {
            guard case .protectedPath = error else {
                return XCTFail("Expected protectedPath, got \(error)")
            }
        }

        try assertRealDirectory(localGroupContainerURL)
        XCTAssertEqual(try String(contentsOf: localGroupContainerURL.appendingPathComponent("payload.txt")), "group-state")
        XCTAssertFalse(fileManager.fileExists(atPath: externalGroupContainerURL.path))
    }

    func testCreateLinkRejectsGroupContainerRootDirectory() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localGroupContainerURL = workspace.homeURL
            .appendingPathComponent("Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat")
        let externalGroupContainerURL = workspace.externalRootURL
            .appendingPathComponent("Group Containers/5A4RE8SF68.com.tencent.xinWeChat")

        try createDirectoryWithPayload(at: externalGroupContainerURL, payload: "group-state")

        do {
            try await makeMover(homeDir: workspace.homeURL).createLink(
                localPath: localGroupContainerURL,
                externalPath: externalGroupContainerURL
            )
            XCTFail("Expected group container root link creation to be rejected")
        } catch let error as DataDirError {
            guard case .protectedPath = error else {
                return XCTFail("Expected protectedPath, got \(error)")
            }
        }

        XCTAssertFalse(fileManager.fileExists(atPath: localGroupContainerURL.path))
        XCTAssertEqual(try String(contentsOf: externalGroupContainerURL.appendingPathComponent("payload.txt")), "group-state")
    }

    func testCreateLinkRejectsExternalRegularFile() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Caches/com.example.file-link")
        let externalFileURL = workspace.externalRootURL
            .appendingPathComponent("Library/Caches/com.example.file-link")

        try fileManager.createDirectory(
            at: externalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not a directory".write(to: externalFileURL, atomically: true, encoding: .utf8)

        do {
            try await makeMover(homeDir: workspace.homeURL).createLink(
                localPath: localDataURL,
                externalPath: externalFileURL
            )
            XCTFail("Expected regular external file to be rejected")
        } catch let error as DataDirError {
            guard case .externalNotFound = error else {
                return XCTFail("Expected externalNotFound, got \(error)")
            }
        }

        XCTAssertFalse(fileManager.fileExists(atPath: localDataURL.path))
        XCTAssertEqual(try String(contentsOf: externalFileURL), "not a directory")
    }

    func testNormalizeManagedLinkRejectsCurrentExternalRegularFileWithoutMovingIt() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Caches/com.example.normalize-file")
        let currentExternalURL = workspace.rootURL
            .appendingPathComponent("ManualStore/com.example.normalize-file")
        let normalizedExternalURL = workspace.externalRootURL
            .appendingPathComponent("Library/Caches/com.example.normalize-file")

        try fileManager.createDirectory(
            at: currentExternalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not a directory".write(to: currentExternalURL, atomically: true, encoding: .utf8)

        do {
            try await makeMover(homeDir: workspace.homeURL).normalizeManagedLink(
                localPath: localDataURL,
                currentExternalPath: currentExternalURL,
                normalizedExternalPath: normalizedExternalURL
            )
            XCTFail("Expected regular current external file to be rejected")
        } catch let error as DataDirError {
            guard case .externalNotFound = error else {
                return XCTFail("Expected externalNotFound, got \(error)")
            }
        }

        XCTAssertFalse(fileManager.fileExists(atPath: localDataURL.path))
        XCTAssertEqual(try String(contentsOf: currentExternalURL), "not a directory")
        XCTAssertFalse(fileManager.fileExists(atPath: normalizedExternalURL.path))
    }

    func testReadOnlyDirectoryMigrationAndRestorePreservesPermissions() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localURL = workspace.homeURL.appendingPathComponent("Library/Application Support/ReadOnly")
        let externalBaseURL = workspace.externalRootURL.appendingPathComponent("Application Support")
        let externalURL = externalBaseURL.appendingPathComponent("ReadOnly")
        try createDirectoryWithPayload(at: localURL, payload: "read-only-data")
        try createDirectoryWithPayload(at: localURL.appendingPathComponent("nested"), payload: "nested-data")
        for url in [localURL.appendingPathComponent("nested"), localURL] {
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        }
        defer {
            for root in [localURL, externalURL] {
                for url in [root, root.appendingPathComponent("nested")] {
                    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
            }
        }

        var item = DataDirItem(name: "ReadOnly", path: localURL, type: .applicationSupport,
                               priority: .critical, description: "Read-only directory fixture")
        let mover = makeMover(homeDir: workspace.homeURL)
        try await mover.migrate(item: item, to: externalBaseURL, progressHandler: nil)
        try assertSymlink(localURL, pointsTo: externalURL)
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL(for: externalURL).path))
        for url in [externalURL, externalURL.appendingPathComponent("nested")] {
            XCTAssertEqual(try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o555)
        }
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: localURL.deletingLastPathComponent().path)
            .contains { $0.hasPrefix(".appports-migration-backup-") })

        item.status = "已链接"
        try await mover.restore(item: item, progressHandler: nil)
        try assertRealDirectory(localURL)
        XCTAssertTrue(fileManager.fileExists(atPath: externalURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: markerURL(for: localURL).path))
        XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("payload.txt")), "read-only-data")
        XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("nested/payload.txt")), "nested-data")
        for url in [localURL, localURL.appendingPathComponent("nested")] {
            XCTAssertEqual(try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o555)
        }
    }

    func testMetadataConflictRetainsPartialCopyAndBlocksRetry() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localURL = workspace.homeURL.appendingPathComponent("Library/Caches/ReadOnly")
        let externalBaseURL = workspace.externalRootURL.appendingPathComponent("Caches")
        let externalURL = externalBaseURL.appendingPathComponent("ReadOnly")
        try createDirectoryWithPayload(at: localURL, payload: "keep-source")
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: localURL.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localURL.path)
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalURL.path)
        }

        let item = DataDirItem(name: "ReadOnly", path: localURL, type: .caches,
                               priority: .optional, description: "Metadata failure fixture")
        let mover = makeMover(homeDir: workspace.homeURL)
        do {
            try await mover.migrate(item: item, to: externalBaseURL) { progress in
                guard progress.currentFile.isEmpty else { return }
                // A conflicting directory at the marker path forces a real atomic write failure.
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalURL.path)
                    try FileManager.default.createDirectory(
                        at: externalURL.appendingPathComponent(".appports-link-metadata.plist"),
                        withIntermediateDirectories: false
                    )
                    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: externalURL.path)
                } catch {
                    XCTFail("Failed to prepare the metadata conflict: \(error)")
                }
            }
            XCTFail("The metadata conflict must fail migration")
        } catch let error as DataDirError {
            guard case .copyFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }

        try assertRealDirectory(localURL)
        XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("payload.txt")), "keep-source")
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: localURL.path)[.posixPermissions] as? Int, 0o555)
        XCTAssertTrue(fileManager.fileExists(atPath: externalURL.path))

        do {
            try await mover.migrate(item: item, to: externalBaseURL, progressHandler: nil)
            XCTFail("Unverified partial copies must block an automatic retry")
        } catch { }
        try assertRealDirectory(localURL)
        XCTAssertEqual(try String(contentsOf: externalURL.appendingPathComponent("payload.txt")), "keep-source")
    }

    func testRestoreRejectsImmutableSourceWithoutTraversingDirectorySymlinks() async throws {
        let workspace = try makeWorkspace()
        let localURL = workspace.homeURL.appendingPathComponent("Cache")
        let externalURL = workspace.externalRootURL.appendingPathComponent("Cache")
        let outsideURL = workspace.rootURL.appendingPathComponent("Unrelated")
        defer {
            try? fileManager.setAttributes([.immutable: false], ofItemAtPath: externalURL.path)
            cleanupWorkspace(workspace.rootURL)
        }
        try createDirectoryWithPayload(at: externalURL, payload: "restore-data")
        try createDirectoryWithPayload(at: outsideURL, payload: "only-unrelated-copy")
        try fileManager.createSymbolicLink(at: externalURL.appendingPathComponent("outside-link"), withDestinationURL: outsideURL)
        try fileManager.createSymbolicLink(at: localURL, withDestinationURL: externalURL)
        // A locked source root prevents any of its entries from being deleted, forcing cleanup to fail.
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: externalURL.path)
        let item = DataDirItem(name: "Cache", path: localURL, type: .custom,
                               priority: .recommended, description: "Locked external cleanup", status: "已链接")

        do {
            try await makeMover(homeDir: workspace.homeURL).restore(item: item, progressHandler: nil)
            XCTFail("Immutable source metadata must fail closed")
        } catch { }

        try assertSymlink(localURL, pointsTo: externalURL)
        XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("payload.txt")), "restore-data")
        try assertSymlink(localURL.appendingPathComponent("outside-link"), pointsTo: outsideURL)
        XCTAssertEqual(try String(contentsOf: outsideURL.appendingPathComponent("payload.txt")), "only-unrelated-copy")
        XCTAssertEqual(try String(contentsOf: externalURL.appendingPathComponent("payload.txt")), "restore-data")
        try assertSymlink(externalURL.appendingPathComponent("outside-link"), pointsTo: outsideURL)
    }

    func testRestoreResolvesRelativeSymlinkFromItsParent() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localURL = workspace.homeURL.appendingPathComponent("Relative")
        let externalURL = workspace.externalRootURL.appendingPathComponent("Relative")
        try createDirectoryWithPayload(at: externalURL, payload: "relative-link-data")
        try fileManager.createSymbolicLink(atPath: localURL.path, withDestinationPath: "../External/Relative")
        let item = DataDirItem(name: "Relative", path: localURL, type: .custom,
                               priority: .recommended, description: "Relative symlink", status: "已链接")
        XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("payload.txt")), "relative-link-data")

        try await makeMover(homeDir: workspace.homeURL).restore(item: item, progressHandler: nil)

        try assertRealDirectory(localURL)
        XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("payload.txt")), "relative-link-data")
        XCTAssertTrue(fileManager.fileExists(atPath: externalURL.path))
    }

    func testRestoreThroughSymlinkedParentUsesActualSourceAndPreservesDecoy() async throws {
        for absoluteTarget in [false, true] {
            let workspace = try makeWorkspace()
            defer { cleanupWorkspace(workspace.rootURL) }
            let actualHomeURL = workspace.rootURL.appendingPathComponent("Actual/Home")
            let homeAliasURL = workspace.rootURL.appendingPathComponent("HomeAlias")
            let actualExternalURL = workspace.rootURL.appendingPathComponent("Actual/External/Real")
            let decoyURL = workspace.externalRootURL.appendingPathComponent("Real")
            try fileManager.createDirectory(at: actualHomeURL, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: homeAliasURL, withDestinationURL: actualHomeURL)
            try createDirectoryWithPayload(at: actualExternalURL, payload: "actual-source")
            try createDirectoryWithPayload(at: decoyURL, payload: "unrelated-decoy")

            let localURL = homeAliasURL.appendingPathComponent("Data")
            let target = absoluteTarget ? homeAliasURL.path + "/../External/Real" : "../External/Real"
            try fileManager.createSymbolicLink(atPath: localURL.path, withDestinationPath: target)
            let item = DataDirItem(name: "Data", path: localURL, type: .custom,
                                   priority: .recommended, description: "Symlinked parent", status: "已链接")
            XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("payload.txt")), "actual-source")

            try await makeMover(homeDir: homeAliasURL).restore(item: item, progressHandler: nil)

            try assertRealDirectory(localURL)
            XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("payload.txt")), "actual-source")
            XCTAssertTrue(fileManager.fileExists(atPath: actualExternalURL.path))
            try assertRealDirectory(decoyURL)
            XCTAssertEqual(try String(contentsOf: decoyURL.appendingPathComponent("payload.txt")), "unrelated-decoy")
            XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: homeAliasURL.path), actualHomeURL.path)
            XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: actualHomeURL.path), ["Data"])
        }
    }

    func testRestoreBrokenLinkThroughSymlinkedParentPreservesTheLinkAndDecoy() async throws {
        for absoluteTarget in [false, true] {
            let workspace = try makeWorkspace()
            defer { cleanupWorkspace(workspace.rootURL) }
            let actualHomeURL = workspace.rootURL.appendingPathComponent("Actual/Home")
            let homeAliasURL = workspace.rootURL.appendingPathComponent("HomeAlias")
            let decoyURL = workspace.externalRootURL.appendingPathComponent("Missing")
            try fileManager.createDirectory(at: actualHomeURL, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: homeAliasURL, withDestinationURL: actualHomeURL)
            try createDirectoryWithPayload(at: decoyURL, payload: "unrelated-decoy")

            let localURL = homeAliasURL.appendingPathComponent("Data")
            let target = absoluteTarget ? homeAliasURL.path + "/../External/Missing" : "../External/Missing"
            try fileManager.createSymbolicLink(atPath: localURL.path, withDestinationPath: target)
            let item = DataDirItem(name: "Data", path: localURL, type: .custom,
                                   priority: .recommended, description: "Broken link with symlinked parent", status: "已链接")
            XCTAssertFalse(fileManager.fileExists(atPath: localURL.path))

            do {
                try await makeMover(homeDir: homeAliasURL).restore(item: item, progressHandler: nil)
                XCTFail("A broken link must not select the unrelated directory at the lexical path")
            } catch let error as DataDirError {
                guard case .externalNotFound = error else { return XCTFail("Unexpected error: \(error)") }
            }

            XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: localURL.path), target)
            XCTAssertFalse(fileManager.fileExists(atPath: localURL.path))
            XCTAssertEqual(try String(contentsOf: decoyURL.appendingPathComponent("payload.txt")), "unrelated-decoy")
            XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: actualHomeURL.path), ["Data"])
        }
    }

    func testRestorePreservesUnrelatedSiblingsWhoseNamesLookLikeStaging() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localURL = workspace.homeURL.appendingPathComponent("Cache")
        let externalURL = workspace.externalRootURL.appendingPathComponent("Cache")
        let siblingDirectoryNames = ["restore-staging-\(UUID().uuidString)", "partial-recovery-\(UUID().uuidString)"]
        let siblingFileName = "notes-partial-recovery-important.txt"
        for name in siblingDirectoryNames {
            try createDirectoryWithPayload(at: workspace.homeURL.appendingPathComponent(name), payload: name)
        }
        try Data("unrelated-notes".utf8).write(to: workspace.homeURL.appendingPathComponent(siblingFileName))
        try createDirectoryWithPayload(at: externalURL, payload: "restore-data")
        try fileManager.createSymbolicLink(at: localURL, withDestinationURL: externalURL)
        let item = DataDirItem(name: "Cache", path: localURL, type: .custom,
                               priority: .recommended, description: "Unrelated siblings", status: "已链接")

        try await makeMover(homeDir: workspace.homeURL).restore(item: item, progressHandler: nil)

        try assertRealDirectory(localURL)
        XCTAssertEqual(try String(contentsOf: localURL.appendingPathComponent("payload.txt")), "restore-data")
        for name in siblingDirectoryNames {
            XCTAssertEqual(try String(contentsOf: workspace.homeURL.appendingPathComponent("\(name)/payload.txt")), name)
        }
        XCTAssertEqual(try Data(contentsOf: workspace.homeURL.appendingPathComponent(siblingFileName)), Data("unrelated-notes".utf8))
        XCTAssertEqual(Set(try fileManager.contentsOfDirectory(atPath: workspace.homeURL.path)),
                       Set(siblingDirectoryNames + [siblingFileName, localURL.lastPathComponent]))
        XCTAssertTrue(fileManager.fileExists(atPath: externalURL.path))
    }

    private struct NoFixtureWriters: ShellCommandRunning {
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        }
    }

    private func makeMover(homeDir: URL, failSymlinkCreation: Bool = false, failSourceBackupCleanup: Bool = false) -> DataDirMover {
        DataDirMover(homeDir: homeDir, failSymlinkCreation: failSymlinkCreation, failSourceBackupCleanup: failSourceBackupCleanup,
            store: ContainerMountStore(fileURL: homeDir.deletingLastPathComponent().appendingPathComponent("data-transfers.plist")), runner: NoFixtureWriters())
    }

    private func makeWorkspace() throws -> (rootURL: URL, homeURL: URL, externalRootURL: URL) {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("DataDirMoverTests-\(UUID().uuidString)")
        let homeURL = rootURL.appendingPathComponent("Home")
        let externalRootURL = rootURL.appendingPathComponent("External")

        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: externalRootURL, withIntermediateDirectories: true)

        return (rootURL, homeURL, externalRootURL)
    }

    private func cleanupWorkspace(_ rootURL: URL) {
        // Retained read-only originals are expected production output; unlock only this owned fixture.
        guard rootURL.lastPathComponent.hasPrefix("DataDirMoverTests-") else { return }
        let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        var directories = [rootURL]
        if let enumerator {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink != true && values?.isDirectory == true { directories.append(url) }
            }
        }
        for directory in directories { _ = chmod(directory.path, 0o755) }
        try? fileManager.removeItem(at: rootURL)
    }

    private func createDirectoryWithPayload(at directoryURL: URL, payload: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try payload.write(
            to: directoryURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func assertSymlink(
        _ localURL: URL,
        pointsTo destinationURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: localURL.path)
        let resolvedDestination = URL(
            fileURLWithPath: destination,
            relativeTo: localURL.deletingLastPathComponent()
        ).standardizedFileURL

        XCTAssertEqual(
            resolvedDestination,
            destinationURL.standardizedFileURL,
            file: file,
            line: line
        )
    }

    private func assertRealDirectory(
        _ directoryURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertEqual(values.isDirectory, true, file: file, line: line)
        XCTAssertThrowsError(
            try fileManager.destinationOfSymbolicLink(atPath: directoryURL.path),
            file: file,
            line: line
        )
    }

    private func markerURL(for directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(".appports-link-metadata.plist")
    }

    private func writeManagedLinkMetadata(
        in directoryURL: URL,
        sourcePath: URL,
        destinationPath: URL,
        type: DataDirType
    ) throws {
        let metadata: [String: Any] = [
            "schemaVersion": 1,
            "managedBy": "com.shimoko.AppPorts",
            "sourcePath": sourcePath.standardizedFileURL.path,
            "destinationPath": destinationPath.standardizedFileURL.path,
            "dataDirType": type.rawValue
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        try data.write(to: markerURL(for: directoryURL), options: .atomic)
    }

    // MARK: - 微信容器迁移策略测试

    func testWeChatApplicationSupportComTencentMigrationAllowed() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let weChatDataURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("WeChatAppSupport")
        let externalDataURL = externalBaseURL.appendingPathComponent(weChatDataURL.lastPathComponent)

        try createDirectoryWithPayload(at: weChatDataURL, payload: "wechat-core")

        let item = DataDirItem(
            name: "com.tencent.xinWeChat",
            path: weChatDataURL,
            type: .containers,
            priority: .critical,
            description: "微信核心数据",
            isMigratable: true
        )

        try await makeMover(homeDir: workspace.homeURL).migrate(
            item: item,
            to: externalBaseURL,
            progressHandler: nil
        )

        try assertSymlink(weChatDataURL, pointsTo: externalDataURL)
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL(for: externalDataURL).path))
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "wechat-core")
    }

    func testWeChatXwechatFilesSubdirectoryMigrationAllowed() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let msgURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/msg")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("WeChatXwechatFiles")
        let externalMsgURL = externalBaseURL.appendingPathComponent("msg")

        try createDirectoryWithPayload(at: msgURL, payload: "chat-messages")

        let item = DataDirItem(
            name: "msg",
            path: msgURL,
            type: .containers,
            priority: .critical,
            description: "微信消息目录",
            isMigratable: true
        )

        try await makeMover(homeDir: workspace.homeURL).migrate(
            item: item,
            to: externalBaseURL,
            progressHandler: nil
        )

        try assertSymlink(msgURL, pointsTo: externalMsgURL)
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL(for: externalMsgURL).path))
        XCTAssertEqual(try String(contentsOf: externalMsgURL.appendingPathComponent("payload.txt")), "chat-messages")
    }

    func testNonWeChatContainerStillUsesUniversalStrategy() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let otherDataURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.example.focus/Data/SomeDataDir")
        let externalBaseURL = workspace.externalRootURL
            .appendingPathComponent("FocusData")
        let externalDataURL = externalBaseURL.appendingPathComponent("SomeDataDir")

        try createDirectoryWithPayload(at: otherDataURL, payload: "focus-stuff")

        let item = DataDirItem(
            name: "SomeDataDir",
            path: otherDataURL,
            type: .containers,
            priority: .critical,
            description: "普通应用数据",
            isMigratable: true
        )

        // 非微信容器不受微信策略影响
        try await makeMover(homeDir: workspace.homeURL).migrate(
            item: item,
            to: externalBaseURL,
            progressHandler: nil
        )

        try assertSymlink(otherDataURL, pointsTo: externalDataURL)
        XCTAssertEqual(try String(contentsOf: externalDataURL.appendingPathComponent("payload.txt")), "focus-stuff")
    }
    func testMigrationRetainsVerifiedOriginalByDefault() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Library/Caches/Retained")
        try createDirectoryWithPayload(at: source, payload: "retained-original")
        let item = DataDirItem(name: "Retained", path: source, type: .caches, priority: .optional, description: "")
        try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        let backup = try XCTUnwrap(try fileManager.contentsOfDirectory(at: source.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".appports-migration-backup-") })
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("payload.txt")), "retained-original")
    }

    func testUnknownSourceManagementMarkerIsNeverOverwritten() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("UnknownMarker")
        try createDirectoryWithPayload(at: source, payload: "original")
        try Data("user-owned-marker".utf8).write(to: source.appendingPathComponent(".appports-link-metadata.plist"))
        let item = DataDirItem(name: "UnknownMarker", path: source, type: .custom, priority: .optional, description: "")
        do {
            try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
            XCTFail("Unknown metadata filename must fail closed")
        } catch { }
        try assertRealDirectory(source)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".appports-link-metadata.plist")), Data("user-owned-marker".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.externalRootURL.appendingPathComponent("UnknownMarker").path))
    }

    func testEveryExactStructuralLockRejectsDirectCreateLinkEvenWithoutUIFlags() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let base = workspace.homeURL.appendingPathComponent("Library/Containers/com.example.fixture/Data")
        let target = workspace.externalRootURL.appendingPathComponent("Existing")
        try createDirectoryWithPayload(at: target, payload: "existing")
        for relative in ["Documents", "Library", "Library/Application Scripts", "Library/Application Support", "Library/Caches",
                         "Library/Images", "Library/Logs", "Library/Preferences", "Library/Saved Application State", "SystemData", "tmp"] {
            let source = base.appendingPathComponent(relative)
            do {
                try await makeMover(homeDir: workspace.homeURL).createLink(localPath: source, externalPath: target)
                XCTFail("Structural path must be rejected: " + relative)
            } catch { }
        }
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload.txt")), "existing")
    }

    func testExplicitCleanupDeletesOnlyVerifiedOriginalAndRestoreRetainsExternal() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Cache")
        let external = workspace.externalRootURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: source, payload: "cleanup-flow")
        let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
        let mover = makeMover(homeDir: workspace.homeURL)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        let migration = try XCTUnwrap(try store.transfers().first)
        XCTAssertEqual(migration.phase, .awaitingUserVerification)
        let backup = URL(fileURLWithPath: try XCTUnwrap(migration.backupPath))
        XCTAssertTrue(fileManager.fileExists(atPath: backup.path))
        try await mover.cleanupRetainedTransfer(operationID: migration.operationID)
        try await mover.cleanupRetainedTransfer(operationID: migration.operationID)
        XCTAssertFalse(fileManager.fileExists(atPath: backup.path))
        XCTAssertEqual(try store.managedLinks().count, 1)
        try await makeMover(homeDir: workspace.homeURL).restore(item: item, progressHandler: nil)
        try await makeMover(homeDir: workspace.homeURL).restore(item: item, progressHandler: nil)
        XCTAssertTrue(fileManager.fileExists(atPath: external.path))
        let restoration = try XCTUnwrap(try store.transfers().first)
        XCTAssertEqual(restoration.direction, .restore)
        XCTAssertEqual(restoration.phase, .awaitingUserVerification)
        try await mover.cleanupRetainedTransfer(operationID: restoration.operationID)
        XCTAssertFalse(fileManager.fileExists(atPath: external.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("payload.txt")), "cleanup-flow")
        XCTAssertTrue(try store.transfers().isEmpty)
    }

    func testCleanupRejectsChangedOriginalButAllowsActiveTargetChanges() async throws {
        for changeOriginal in [false, true] {
            let workspace = try makeWorkspace()
            defer { cleanupWorkspace(workspace.rootURL) }
            let source = workspace.homeURL.appendingPathComponent("Cache")
            let external = workspace.externalRootURL.appendingPathComponent("Cache")
            try createDirectoryWithPayload(at: source, payload: "before")
            let mover = makeMover(homeDir: workspace.homeURL)
            let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
            try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
            let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
            let transfer = try XCTUnwrap(try store.transfers().first)
            let backup = URL(fileURLWithPath: try XCTUnwrap(transfer.backupPath))
            let changed = (changeOriginal ? backup : external).appendingPathComponent("payload.txt")
            let oldTime = try fileManager.attributesOfItem(atPath: changed.path)[.modificationDate]
            try Data("after!".utf8).write(to: changed)
            if let oldTime { try fileManager.setAttributes([.modificationDate: oldTime], ofItemAtPath: changed.path) }
            if changeOriginal {
                do { try await mover.cleanupRetainedTransfer(operationID: transfer.operationID); XCTFail("Changed original cannot be deleted") }
                catch { }
                XCTAssertEqual(try String(contentsOf: changed), "after!")
                XCTAssertEqual(try store.transfers().first?.phase, .awaitingUserVerification)
            } else {
                try await mover.cleanupRetainedTransfer(operationID: transfer.operationID)
                XCTAssertFalse(fileManager.fileExists(atPath: backup.path))
                XCTAssertEqual(try String(contentsOf: changed), "after!")
            }
        }
    }

    func testLateSameSizeSourceWriteWithRestoredMtimeBlocksSwitch() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Cache")
        let payload = source.appendingPathComponent("payload.txt")
        try createDirectoryWithPayload(at: source, payload: "before")
        let oldTime = try XCTUnwrap(try fileManager.attributesOfItem(atPath: payload.path)[.modificationDate] as? Date)
        let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
        do {
            try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: workspace.externalRootURL) { progress in
                if progress.currentFile == "正在切换本地入口...".localized {
                    try? Data("after!".utf8).write(to: payload)
                    try? FileManager.default.setAttributes([.modificationDate: oldTime], ofItemAtPath: payload.path)
                }
            }
            XCTFail("Late content change must prevent switching")
        } catch { }
        try assertRealDirectory(source)
        XCTAssertEqual(try String(contentsOf: payload), "after!")
        XCTAssertEqual(try String(contentsOf: workspace.externalRootURL.appendingPathComponent("Cache/payload.txt")), "before")
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        XCTAssertEqual(try store.transfers().first?.phase, .needsRecovery)
    }

    func testDestinationSymlinkIsNotRemovedOrReused() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Cache")
        let unrelated = workspace.rootURL.appendingPathComponent("Unrelated")
        let destination = workspace.externalRootURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: source, payload: "source")
        try createDirectoryWithPayload(at: unrelated, payload: "unrelated")
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: unrelated)
        let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
        do { try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: workspace.externalRootURL, progressHandler: nil); XCTFail("Destination link must remain") }
        catch { }
        try assertSymlink(destination, pointsTo: unrelated)
        XCTAssertEqual(try String(contentsOf: unrelated.appendingPathComponent("payload.txt")), "unrelated")
        try assertRealDirectory(source)
    }

    func testIntentWriteFailureOccursBeforeDestinationCreation() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: source, payload: "source")
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("failed.plist"), writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let mover = DataDirMover(homeDir: workspace.homeURL, store: store, runner: NoFixtureWriters())
        let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
        let newParent = workspace.externalRootURL.appendingPathComponent("new-parent")
        do { try await mover.migrate(item: item, to: newParent, progressHandler: nil); XCTFail("Failed intent must stop before copy") }
        catch { }
        XCTAssertFalse(fileManager.fileExists(atPath: newParent.path))
        try assertRealDirectory(source)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("payload.txt")), "source")
    }

    func testSwitchIntentAndFinalCommitWriteFailuresRetainBothCopies() async throws {
        for failingPhase in ["switching", "awaitingUserVerification"] {
            let workspace = try makeWorkspace()
            defer { cleanupWorkspace(workspace.rootURL) }
            let source = workspace.homeURL.appendingPathComponent("Cache")
            let destination = workspace.externalRootURL.appendingPathComponent("Cache")
            try createDirectoryWithPayload(at: source, payload: "durable-data")
            let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("phase-failure.plist"), writeData: { data, url in
                let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                let records = document?["transfers"] as? [[String: Any]] ?? []
                if records.contains(where: { $0["phase"] as? String == failingPhase }) { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            let mover = DataDirMover(homeDir: workspace.homeURL, store: store, runner: NoFixtureWriters())
            let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
            do { try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil); XCTFail("Durability failure must be surfaced") }
            catch { }
            let transfer = try XCTUnwrap(try store.transfers().first)
            XCTAssertEqual(transfer.phase, .needsRecovery)
            let retained = failingPhase == "switching" ? source : URL(fileURLWithPath: try XCTUnwrap(transfer.backupPath))
            XCTAssertEqual(try String(contentsOf: retained.appendingPathComponent("payload.txt")), "durable-data")
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload.txt")), "durable-data")
            if failingPhase == "switching" { try assertRealDirectory(source) }
            else { try assertSymlink(source, pointsTo: destination) }
        }
    }

    func testCleanupIntentWriteFailurePreventsDeletingRetainedOriginal() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: source, payload: "original")
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("cleanup-failure.plist"), writeData: { data, url in
            let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let records = document?["transfers"] as? [[String: Any]] ?? []
            if records.contains(where: { $0["phase"] as? String == "cleanupRequested" }) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let mover = DataDirMover(homeDir: workspace.homeURL, store: store, runner: NoFixtureWriters())
        let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
        try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        let transfer = try XCTUnwrap(try store.transfers().first)
        let backup = URL(fileURLWithPath: try XCTUnwrap(transfer.backupPath))
        do { try await mover.cleanupRetainedTransfer(operationID: transfer.operationID); XCTFail("Failed cleanup intent must preserve original") }
        catch { }
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("payload.txt")), "original")
        XCTAssertEqual(try store.transfers().first?.phase, .awaitingUserVerification)
        try assertSymlink(source, pointsTo: workspace.externalRootURL.appendingPathComponent("Cache"))
    }

    func testCleanupRejectsReplacedActiveIdentityEvenIfContentsMatch() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Cache")
        let external = workspace.externalRootURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: source, payload: "original")
        let mover = makeMover(homeDir: workspace.homeURL)
        let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
        try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        let transfer = try XCTUnwrap(try store.transfers().first)
        try fileManager.moveItem(at: external, to: workspace.externalRootURL.appendingPathComponent("moved-active"))
        try createDirectoryWithPayload(at: external, payload: "original")
        do { try await mover.cleanupRetainedTransfer(operationID: transfer.operationID); XCTFail("Unrelated active inode cannot authorize deletion") }
        catch { }
        let backup = URL(fileURLWithPath: try XCTUnwrap(transfer.backupPath))
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("payload.txt")), "original")
        XCTAssertEqual(try store.transfers().first?.phase, .awaitingUserVerification)
    }

    func testCleanupCompletionWriteFailureStillRequiresRecoveryAfterPhysicalDeletion() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let local = workspace.homeURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: local, payload: "keep-active")
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("finish-failure.plist"), writeData: { data, url in
            let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            if (document?["transfers"] as? [Any])?.isEmpty == true { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let mover = DataDirMover(homeDir: workspace.homeURL, store: store, runner: NoFixtureWriters())
        let item = DataDirItem(name: "Cache", path: local, type: .custom, priority: .optional, description: "")
        try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        let transfer = try XCTUnwrap(try store.transfers().first)
        do { try await mover.cleanupRetainedTransfer(operationID: transfer.operationID); XCTFail("Failed completion record must be surfaced") }
        catch { }
        XCTAssertFalse(fileManager.fileExists(atPath: try XCTUnwrap(transfer.backupPath)))
        XCTAssertEqual(try store.transfer(operationID: transfer.operationID)?.phase, .needsRecovery)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("payload.txt")), "keep-active")
        let file = workspace.rootURL.appendingPathComponent("finish-failure.plist")
        let ledger = try Data(contentsOf: file)
        let recovery = try XCTUnwrap(try store.transfer(operationID: transfer.operationID))
        let active = URL(fileURLWithPath: recovery.destinationPath)
        let activeSnapshot = try TreeCopySession.snapshot(at: active)
        let linkIdentity = try DataPathIdentity.capture(local)
        for _ in 0..<2 {
            let coldStore = ContainerMountStore(fileURL: file)
            let coldMover = DataDirMover(homeDir: workspace.homeURL, store: coldStore, runner: NoFixtureWriters())
            do {
                try await coldMover.cleanupRetainedTransfer(operationID: transfer.operationID)
                XCTFail("Persisted recovery must refuse a second physical cleanup")
            } catch { }
            XCTAssertEqual(try coldStore.unfinishedTransfers(), [recovery])
            XCTAssertEqual(try Data(contentsOf: file), ledger)
            XCTAssertFalse(fileManager.fileExists(atPath: try XCTUnwrap(recovery.backupPath)))
            XCTAssertEqual(try DataPathIdentity.capture(local), linkIdentity)
            try assertSymlink(local, pointsTo: active)
            XCTAssertEqual(try TreeCopySession.snapshot(at: active), activeSnapshot)
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("payload.txt")), "keep-active")
        }
    }

    func testColdStoreCleanupAcceptsDeviceRenumberingOnlyWithMatchingVolumeUUID() async throws {
        for identityCase in ["same-volume", "different-volume", "legacy-no-volume"] {
            let workspace = try makeWorkspace()
            defer { cleanupWorkspace(workspace.rootURL) }
            let source = workspace.homeURL.appendingPathComponent("Cache")
            try createDirectoryWithPayload(at: source, payload: "persistent")
            let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
            try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
            let storeURL = workspace.rootURL.appendingPathComponent("data-transfers.plist")
            let before = try XCTUnwrap(try ContainerMountStore(fileURL: storeURL).transfers().first)
            XCTAssertNotNil(before.backupIdentity?.volumeUUID)
            let backup = URL(fileURLWithPath: try XCTUnwrap(before.backupPath))

            // Reproduce an old persisted st_dev after the same filesystem is reattached.
            // This changes only the synthetic fixture's document, never a real volume.
            func renumber(_ value: Any) throws -> Any {
                if var dictionary = value as? [String: Any] {
                    for (key, child) in dictionary { dictionary[key] = try renumber(child) }
                    if let device = dictionary["device"] as? NSNumber { dictionary["device"] = device.int64Value + 100 }
                    if dictionary["volumeUUID"] != nil {
                        if identityCase == "different-volume" { dictionary["volumeUUID"] = "11111111-2222-3333-4444-555555555555" }
                        if identityCase == "legacy-no-volume" { dictionary.removeValue(forKey: "volumeUUID") }
                    }
                    if let encoded = dictionary["baseline"] as? Data {
                        let baseline = try PropertyListSerialization.propertyList(from: encoded, format: nil)
                        dictionary["baseline"] = try PropertyListSerialization.data(fromPropertyList: renumber(baseline), format: .binary, options: 0)
                    }
                    return dictionary
                }
                if let values = value as? [Any] { return try values.map(renumber) }
                return value
            }
            let document = try PropertyListSerialization.propertyList(from: Data(contentsOf: storeURL), format: nil)
            try PropertyListSerialization.data(fromPropertyList: renumber(document), format: .binary, options: 0).write(to: storeURL, options: .atomic)
            let coldMover = makeMover(homeDir: workspace.homeURL)
            if identityCase == "same-volume" {
                try await coldMover.cleanupRetainedTransfer(operationID: before.operationID)
                XCTAssertFalse(fileManager.fileExists(atPath: backup.path))
            } else {
                do { try await coldMover.cleanupRetainedTransfer(operationID: before.operationID); XCTFail("Unproven volume identity must preserve the original") }
                catch { }
                XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("payload.txt")), "persistent")
            }
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("payload.txt")), "persistent")
        }
    }

    func testMigrationNormalizationRestorePreservesAllHistoricalOriginals() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let local = workspace.homeURL.appendingPathComponent("Cache")
        let firstTarget = workspace.externalRootURL.appendingPathComponent("Cache")
        let normalized = workspace.rootURL.appendingPathComponent("Normalized/Cache")
        try createDirectoryWithPayload(at: local, payload: "history")
        let item = DataDirItem(name: "Cache", path: local, type: .custom, priority: .optional, description: "")
        let mover = makeMover(homeDir: workspace.homeURL)
        try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        try await mover.normalizeManagedLink(localPath: local, currentExternalPath: firstTarget, normalizedExternalPath: normalized)
        try assertSymlink(local, pointsTo: normalized)
        XCTAssertTrue(fileManager.fileExists(atPath: firstTarget.path))
        try await mover.restore(item: item, progressHandler: nil)
        try assertRealDirectory(local)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("payload.txt")), "history")
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        let history = try store.transfers()
        XCTAssertEqual(history.count, 3)
        XCTAssertTrue(history.allSatisfy { $0.phase == .awaitingUserVerification })
        for transfer in history {
            XCTAssertTrue(fileManager.fileExists(atPath: try XCTUnwrap(transfer.backupPath)))
        }
    }

    func testCleanupLineagePreflightFailureRemainsRetryableAfterAncestorCleanup() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let local = workspace.homeURL.appendingPathComponent("Cache")
        let firstTarget = workspace.externalRootURL.appendingPathComponent("Cache")
        let normalized = workspace.rootURL.appendingPathComponent("Normalized/Cache")
        try createDirectoryWithPayload(at: local, payload: "history")
        let item = DataDirItem(name: "Cache", path: local, type: .custom, priority: .optional, description: "")
        let mover = makeMover(homeDir: workspace.homeURL)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        let first = try XCTUnwrap(try store.transfers().first)
        try await mover.normalizeManagedLink(localPath: local, currentExternalPath: firstTarget, normalizedExternalPath: normalized)
        let middle = try XCTUnwrap(try store.transfers().first { $0.priorOperationID == first.operationID })
        try await mover.restore(item: item, progressHandler: nil)
        let last = try XCTUnwrap(try store.transfers().first { $0.priorOperationID == middle.operationID })
        do { try await mover.cleanupRetainedTransfer(operationID: middle.operationID); XCTFail("Middle lineage proof is still needed") }
        catch { }
        XCTAssertEqual(try store.transfer(operationID: middle.operationID)?.phase, .awaitingUserVerification)
        XCTAssertEqual(try String(contentsOf: firstTarget.appendingPathComponent("payload.txt")), "history")
        try await mover.cleanupRetainedTransfer(operationID: first.operationID)
        try await mover.cleanupRetainedTransfer(operationID: middle.operationID)
        try await mover.cleanupRetainedTransfer(operationID: last.operationID)
        XCTAssertTrue(try store.transfers().isEmpty)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("payload.txt")), "history")
    }

    func testUnavailableRetainedTreeDoesNotAdvanceCleanupAndCanRetryWhenItReturns() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let local = workspace.homeURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: local, payload: "offline")
        let item = DataDirItem(name: "Cache", path: local, type: .custom, priority: .optional, description: "")
        let mover = makeMover(homeDir: workspace.homeURL)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        let transfer = try XCTUnwrap(try store.transfers().first)
        let backup = URL(fileURLWithPath: try XCTUnwrap(transfer.backupPath))
        let unavailable = workspace.rootURL.appendingPathComponent("temporarily-unavailable")
        try DataTreeRelocator.move(backup, to: unavailable)
        do { try await mover.cleanupRetainedTransfer(operationID: transfer.operationID); XCTFail("Missing retained source is not deletable") }
        catch { }
        XCTAssertEqual(try store.transfer(operationID: transfer.operationID)?.phase, .awaitingUserVerification)
        try DataTreeRelocator.move(unavailable, to: backup)
        try await mover.cleanupRetainedTransfer(operationID: transfer.operationID)
        XCTAssertTrue(try store.transfers().isEmpty)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("payload.txt")), "offline")
    }

    func testMarkerCreatedInRenamedOriginalCannotBeSilentlyExcluded() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: source, payload: "history")
        let rootTime = try XCTUnwrap(try fileManager.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
        do {
            try await makeMover(homeDir: workspace.homeURL).migrate(item: item, to: workspace.externalRootURL) { progress in
                guard progress.currentFile == "正在创建符号链接...".localized,
                      let path = try? store.transfers().first?.backupPath else { return }
                let backup = URL(fileURLWithPath: path)
                try? Data("unknown".utf8).write(to: backup.appendingPathComponent(".appports-link-metadata.plist"))
                try? FileManager.default.setAttributes([.modificationDate: rootTime], ofItemAtPath: backup.path)
            }
            XCTFail("New marker in retained original must stop the switch")
        } catch { }
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        let transfer = try XCTUnwrap(try store.transfers().first)
        let backup = URL(fileURLWithPath: try XCTUnwrap(transfer.backupPath))
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent(".appports-link-metadata.plist")), "unknown")
        XCTAssertEqual(transfer.phase, .needsRecovery)
    }

    func testTakingOverMatchingExistingLinkPreservesItsEntryIdentity() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let local = workspace.homeURL.appendingPathComponent("Existing")
        let external = workspace.externalRootURL.appendingPathComponent("Existing")
        try createDirectoryWithPayload(at: external, payload: "existing")
        try fileManager.createSymbolicLink(at: local, withDestinationURL: external)
        let before = try DataPathIdentity.capture(local)
        try await makeMover(homeDir: workspace.homeURL).createLink(localPath: local, externalPath: external)
        XCTAssertEqual(try DataPathIdentity.capture(local), before)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        XCTAssertEqual(try store.managedLinks().count, 1)
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("payload.txt")), "existing")
    }

    func testManagedLinkCanReconnectWhileItsVerifiedOriginalIsRetained() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let source = workspace.homeURL.appendingPathComponent("Cache")
        let external = workspace.externalRootURL.appendingPathComponent("Cache")
        try createDirectoryWithPayload(at: source, payload: "retained")
        let item = DataDirItem(name: "Cache", path: source, type: .custom, priority: .optional, description: "")
        let mover = makeMover(homeDir: workspace.homeURL)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("data-transfers.plist"))
        try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
        let retained = try XCTUnwrap(try store.transfers().first)
        try await mover.deleteLink(localPath: source)
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        try await mover.createLink(localPath: source, externalPath: external)
        try assertSymlink(source, pointsTo: external)
        XCTAssertEqual(try store.transfer(operationID: retained.operationID)?.phase, .awaitingUserVerification)
        let backup = URL(fileURLWithPath: try XCTUnwrap(retained.backupPath))
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("payload.txt")), "retained")
    }

    func testStructuralPolicyAppliesToAllLowLevelEntrypointsWithSpoofedFlags() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let root = workspace.homeURL.appendingPathComponent("Library/Containers/com.example.fixture")
        let target = workspace.externalRootURL.appendingPathComponent("Existing")
        try createDirectoryWithPayload(at: target, payload: "existing")
        let paths = ["", "Data", "Data/Documents", "Data/Library", "Data/Library/Application Scripts", "Data/Library/Application Support",
                     "Data/Library/Caches", "Data/Library/Images", "Data/Library/Logs", "Data/Library/Preferences",
                     "Data/Library/Saved Application State", "Data/SystemData", "Data/tmp"]
        for relative in paths {
            let source = root.appendingPathComponent(relative)
            try createDirectoryWithPayload(at: source, payload: "source")
            let item = DataDirItem(name: "Spoofed", path: source, type: .custom, priority: .optional, description: "", isMigratable: true, requiresMountMigration: false)
            for operation in 0..<3 {
                do {
                    let mover = makeMover(homeDir: workspace.homeURL)
                    switch operation {
                    case 0: try await mover.migrate(item: item, to: workspace.externalRootURL, progressHandler: nil)
                    case 1: try await mover.createLink(localPath: source, externalPath: target)
                    default: try await mover.normalizeManagedLink(localPath: source, currentExternalPath: target, normalizedExternalPath: workspace.externalRootURL.appendingPathComponent("Next"))
                    }
                    XCTFail("Policy bypass: " + relative)
                } catch let error as DataDirError {
                    guard case .protectedPath = error else { return XCTFail("Expected policy denial, got \(error)") }
                }
            }
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("payload.txt")), "source")
        }
    }

    func testHistoricalLockedDirectoryCanRestoreWithoutGrantingNewMigration() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let local = workspace.homeURL.appendingPathComponent("Library/Containers/com.example.fixture/Data/Documents")
        let external = workspace.externalRootURL.appendingPathComponent("Documents")
        try createDirectoryWithPayload(at: external, payload: "historic")
        try fileManager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: local, withDestinationURL: external)
        let item = DataDirItem(name: "Documents", path: local, type: .containers, priority: .critical, description: "", status: DataDirStatus.needsNormalization, isMigratable: false)
        try await makeMover(homeDir: workspace.homeURL).restore(item: item, progressHandler: nil)
        try assertRealDirectory(local)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("payload.txt")), "historic")
        XCTAssertTrue(fileManager.fileExists(atPath: external.path))
        XCTAssertFalse(DataPathPolicy(homeDirectory: workspace.homeURL).evaluate(local).canMigrate)
    }

    func testRestoreRefusesManagedOrExternalSymlinkAncestor() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let parent = workspace.homeURL.appendingPathComponent("Parent")
        let externalParent = workspace.externalRootURL.appendingPathComponent("Parent")
        let externalData = workspace.externalRootURL.appendingPathComponent("Data")
        try fileManager.createDirectory(at: externalParent, withIntermediateDirectories: true)
        try createDirectoryWithPayload(at: externalData, payload: "keep")
        try fileManager.createSymbolicLink(at: parent, withDestinationURL: externalParent)
        let local = parent.appendingPathComponent("Data")
        try fileManager.createSymbolicLink(at: local, withDestinationURL: externalData)
        let item = DataDirItem(name: "Data", path: local, type: .custom, priority: .optional, description: "", status: DataDirStatus.linked)
        do { try await makeMover(homeDir: workspace.homeURL).restore(item: item, progressHandler: nil); XCTFail("Restore inside linked parent is not local recovery") }
        catch { }
        try assertSymlink(parent, pointsTo: externalParent)
        try assertSymlink(local, pointsTo: externalData)
        XCTAssertEqual(try String(contentsOf: externalData.appendingPathComponent("payload.txt")), "keep")
    }

}
