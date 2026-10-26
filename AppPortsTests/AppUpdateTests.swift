import CryptoKit
import XCTest
@testable import AppPorts

final class AppUpdateTests: XCTestCase {
    func testReleaseAssetSelectionAcceptsCurrentDMGNamingAndRequiresDigest() {
        let dmg = asset("AppPorts2.0.1.dmg")
        XCTAssertEqual(GitHubUpdateAsset.select(from: [dmg]), dmg)
        XCTAssertNil(GitHubUpdateAsset.select(from: [asset("AppPorts2.0.1.dmg", digest: nil)]))
    }

    func testReleaseAssetSelectionRejectsForeignRepositoryAndWrongArchitecture() {
        let foreign = asset("AppPorts.zip", url: "https://github.com/other/repo/releases/download/2.0.1/AppPorts.zip")
        let arm = asset("AppPorts-arm64.zip")
        let intel = asset("AppPorts-x86_64.zip")
        XCTAssertEqual(GitHubUpdateAsset.select(from: [foreign, arm, intel], architecture: "arm64"), arm)
        XCTAssertEqual(GitHubUpdateAsset.select(from: [arm, intel], architecture: "x86_64"), intel)
        XCTAssertNil(GitHubUpdateAsset.select(from: [intel], architecture: "arm64"))
    }

    func testAmbiguousAssetsAndUntrustedSchemesAreRejected() {
        XCTAssertNil(GitHubUpdateAsset.select(from: [asset("AppPorts-a.zip"), asset("AppPorts-b.zip")]))
        XCTAssertFalse(asset("AppPorts.zip", url: "http://github.com/wzh4869/AppPorts/releases/download/2.0.1/AppPorts.zip").isSupported)
        XCTAssertFalse(asset("AppPorts-symbols.zip").isSupported)
    }

    func testReleaseMetadataWithoutAssetsStillDecodesForManualDownload() throws {
        let data = Data(#"{"tag_name":"2.0.1","html_url":"https://github.com/wzh4869/AppPorts/releases/tag/2.0.1","body":"notes"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ReleaseInfo.self, from: data).assets)
    }

    func testArchiveChecksumAndSizeMustBothMatch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("update.zip")
        let contents = Data("verified release".utf8)
        try contents.write(to: archive)
        let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let valid = asset("AppPorts.zip", digest: "sha256:" + hash, size: Int64(contents.count))
        XCTAssertNoThrow(try GitHubUpdatePackage.verifyArchive(at: archive, asset: valid))
        XCTAssertThrowsError(try GitHubUpdatePackage.verifyArchive(at: archive, asset: asset("AppPorts.zip", size: Int64(contents.count))))
        XCTAssertThrowsError(try GitHubUpdatePackage.verifyArchive(at: archive, asset: asset("AppPorts.zip", digest: "sha256:" + hash, size: 999)))
    }

    func testInstallerWaitsForRunningApplicationWithoutReplacingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let result = try await fixture.run(parentPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try fixture.targetText(), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.update.stagedApplication.path))
    }

    func testInstallerReplacesAndCleansOnlyAfterLaunchAcknowledgement() async throws {
        let fixture = try Fixture(name: "AppPorts quote ' and space")
        defer { fixture.clean() }
        let result = try await fixture.run(launch: ["/usr/bin/touch", fixture.update.workspace.appendingPathComponent("launched").path])
        XCTAssertEqual(result.status, 0, result.combinedText)
        XCTAssertEqual(try fixture.targetText(), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.update.workspace.path))
    }

    func testInstallerRetainsBackupWhenOpenDoesNotConfirmLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let result = try await fixture.run()
        XCTAssertEqual(result.status, 0, result.combinedText)
        XCTAssertEqual(try fixture.targetText(), "new")
        XCTAssertEqual(try String(contentsOf: fixture.update.workspace.appendingPathComponent("Previous.app/value")), "old")
    }

    func testFailedRelaunchRestoresOriginalAndRetainsNewCandidate() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let result = try await fixture.run(launch: ["/usr/bin/false"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try fixture.targetText(), "old")
        XCTAssertEqual(try String(contentsOf: fixture.update.stagedApplication.appendingPathComponent("value")), "new")
    }

    func testChangedDestinationIsNeverOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        // Keep the original inode allocated so the replacement cannot reuse it.
        try FileManager.default.moveItem(at: fixture.update.destination, to: fixture.root.appendingPathComponent("moved-original"))
        try FileManager.default.createDirectory(at: fixture.update.destination, withIntermediateDirectories: false)
        try "other".write(to: fixture.update.destination.appendingPathComponent("value"), atomically: true, encoding: .utf8)
        let result = try await fixture.run()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try fixture.targetText(), "other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.update.stagedApplication.path))
    }

    @MainActor
    func testUpdateTerminationRequiresSoleOperationOwnership() {
        let state = AppOperationState()
        guard let token = state.begin() else { return XCTFail("Expected token") }
        XCTAssertTrue(state.isOnlyOperation(token))
        XCTAssertFalse(state.isOnlyOperation(UUID()))
        state.setMigrationCount(1)
        XCTAssertFalse(state.isOnlyOperation(token))
        state.setMigrationCount(0)
        XCTAssertTrue(state.isOnlyOperation(token))
        state.finish(token)
        XCTAssertFalse(state.isOnlyOperation(token))
    }

    private func asset(_ name: String, digest: String? = "sha256:" + String(repeating: "a", count: 64),
                       size: Int64 = 10, url: String? = nil) -> GitHubUpdateAsset {
        GitHubUpdateAsset(name: name, size: size,
            browserDownloadURL: URL(string: url ?? "https://github.com/wzh4869/AppPorts/releases/download/2.0.1/\(name)")!, digest: digest)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsUpdateTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private struct Fixture {
        let root: URL
        let update: PreparedAppUpdate

        init(name: String = "AppPorts") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsUpdateTests-" + UUID().uuidString)
            let target = root.appendingPathComponent(name + ".app")
            let workspace = root.appendingPathComponent(".AppPorts-update-" + UUID().uuidString)
            let staged = workspace.appendingPathComponent("AppPorts.app")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try "old".write(to: target.appendingPathComponent("value"), atomically: true, encoding: .utf8)
            try "new".write(to: staged.appendingPathComponent("value"), atomically: true, encoding: .utf8)
            update = PreparedAppUpdate(workspace: workspace, destination: target,
                originalIdentity: try GitHubUpdatePackage.identity(at: target),
                stagedIdentity: try GitHubUpdatePackage.identity(at: staged), version: "2.0.1")
        }

        func targetText() throws -> String { try String(contentsOf: update.destination.appendingPathComponent("value")) }
        func clean() { try? FileManager.default.removeItem(at: root) }

        func run(parentPID: Int32 = Int32.max, launch: [String] = ["/usr/bin/true"]) async throws -> ShellCommandResult {
            let script = AppUpdateInstaller.script(for: update, parentPID: parentPID, relaunchCommand: launch,
                recoveryCommand: ["/usr/bin/true"], failureCommand: ["/usr/bin/true"], waitAttempts: 0)
            let url = root.appendingPathComponent("test.sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            return try await ProcessCommandRunner().run(executable: "/bin/sh", arguments: [url.path], timeout: 10)
        }
    }
}
