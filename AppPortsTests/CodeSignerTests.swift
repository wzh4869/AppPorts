import Darwin
import Foundation
import Testing
@testable import AppPorts

/// 真实证书签名的测试应用，只读取、从不修改。
///
/// 优先用 `APPPORTS_SIGNED_TEST_APP` 指定的应用；否则取当前 Xcode 自带的 Apple 签名工具，
/// 跑测试时它一定在。系统卷上的平台应用不能再当回退：macOS 27 上复制出来的副本会以
/// "resource envelope is obsolete (custom omit rules)" 校验失败。
/// 找不到复制后仍能严格校验的应用时，相关测试标为跳过，而不是误报签名逻辑失败。
private enum SignedTestApplication {
    static let source: URL? = {
        let configured = ProcessInfo.processInfo.environment["APPPORTS_SIGNED_TEST_APP"].flatMap { path -> URL? in
            let app = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            guard app.path.hasPrefix(temporary + "/"),
                  CodeSigner.bundleIdentifier(at: app)?.hasPrefix("com.appports.tests.") == true else { return nil }
            return app
        }
        return ([configured].compactMap { $0 } + xcodeBundledApplications).lazy
            .compactMap { try? CodeSigner.resolveAppURL(at: $0) }
            .first(where: verifiesStrictlyAfterCopy)
    }()

    private static var xcodeBundledApplications: [URL] {
        // Only Xcode's bundled tools are approved real signed inputs. Every
        // signing/moving/deleting operation below targets a temporary copy.
        var roots = Bundle.allFrameworks.map(\.bundlePath).compactMap { path -> URL? in
            guard path.hasSuffix("/Testing.framework") || path.hasSuffix("/XCTest.framework"),
                  let range = path.range(of: ".app/Contents/") else { return nil }
            return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        }
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           let range = developer.range(of: ".app/Contents/") {
            roots.append(URL(fileURLWithPath: String(developer[..<range.lowerBound]) + ".app"))
        }
        roots.append(URL(fileURLWithPath: "/Applications/Xcode.app"))
        return roots.flatMap { xcode in
            ["Accessibility Inspector.app", "FileMerge.app"].map {
                xcode.appendingPathComponent("Contents/Applications").appendingPathComponent($0)
            }
        }
    }

    private static func verifiesStrictlyAfterCopy(_ app: URL) -> Bool {
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsSignedTestApplication-\(UUID().uuidString)")
        defer { try? SignatureSnapshot.remove(probe) }
        do {
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
            let copy = probe.appendingPathComponent(app.lastPathComponent)
            try SignatureSnapshot.copy(from: app, to: copy)
            // Fixture eligibility must be independent of the inspector under
            // test, otherwise losing developer evidence silently skips it.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--deep", "--strict", copy.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                return false
            }
            return process.terminationStatus == 0
        } catch { return false }
    }
}

@Suite("Code signing")
struct CodeSignerTests {
    enum PortalKind: CaseIterable {
        case native, legacyScript, wholeAppSymlink, contentsSymlink
    }

    @Test("Every supported portal resolves to the real application", arguments: PortalKind.allCases)
    func resolvesRealApplication(kind: PortalKind) throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat's app.app")
        try makeBundle(at: realApp)
        let portal = workspace.root.appendingPathComponent("Chat.app")

        switch kind {
        case .native:
            try makeBundle(at: portal, identifier: "com.appports.tests.chat.appports.stub")
            try (realApp.path + "\n").write(
                to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"),
                atomically: true, encoding: .utf8
            )
        case .legacyScript:
            try makeBundle(at: portal, identifier: "com.appports.tests.chat.appports.stub")
            let quotedPath = realApp.path.replacingOccurrences(of: "'", with: "'\\''")
            try "#!/bin/bash\nREAL_APP='\(quotedPath)'\nopen \"$REAL_APP\"\n".write(
                to: portal.appendingPathComponent("Contents/MacOS/launcher"),
                atomically: true, encoding: .utf8
            )
        case .wholeAppSymlink:
            try FileManager.default.createSymbolicLink(atPath: portal.path, withDestinationPath: "External/Chat's app.app")
        case .contentsSymlink:
            try FileManager.default.createDirectory(at: portal, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: portal.appendingPathComponent("Contents").path,
                withDestinationPath: "../External/Chat's app.app/Contents"
            )
        }

        #expect(try CodeSigner.resolveAppURL(at: portal).path == realApp.path)
    }

    enum BrokenPortal: CaseIterable {
        case missingTarget, emptyPath, relativePath, missingMetadata, cycle, brokenMetadataLink
    }

    @Test("Broken portals fail before the stub or backups are modified", arguments: BrokenPortal.allCases)
    func refusesBrokenPortal(kind: BrokenPortal) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let portal = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: portal, identifier: "com.appports.tests.chat.appports.stub")
        let pathFile = portal.appendingPathComponent("Contents/Resources/real_app_path.txt")
        switch kind {
        case .missingTarget:
            try workspace.root.appendingPathComponent("Missing.app").path.write(to: pathFile, atomically: true, encoding: .utf8)
        case .emptyPath:
            try "\n".write(to: pathFile, atomically: true, encoding: .utf8)
        case .relativePath:
            try "../Missing.app".write(to: pathFile, atomically: true, encoding: .utf8)
        case .missingMetadata:
            break
        case .cycle:
            try portal.path.write(to: pathFile, atomically: true, encoding: .utf8)
        case .brokenMetadataLink:
            try FileManager.default.createSymbolicLink(atPath: pathFile.path, withDestinationPath: "missing.txt")
        }
        let executable = portal.appendingPathComponent("Contents/MacOS/Fixture")
        let original = try Data(contentsOf: executable)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })

        do {
            try await signer.sign(appURL: portal, bundleIdentifier: nil)
            Issue.record("A broken portal must not be signed as a normal application")
        } catch CodeSigner.SigningError.applicationUnavailable {
            // Expected: fail before changing the local portal.
        }

        #expect(try Data(contentsOf: executable) == original)
        #expect(FileManager.default.fileExists(atPath: workspace.backups.path) == false)
    }

    @Test("A legacy fixture records the real application behind a portal")
    func backupUsesRealApplication() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat.app")
        let identifier = "com.appports.tests.real-chat"
        try makeBundle(at: realApp, identifier: identifier)
        let portal = workspace.root.appendingPathComponent("Chat.app")
        let stubIdentifier = identifier + ".appports.stub"
        try makeBundle(at: portal, identifier: stubIdentifier)
        try realApp.path.write(to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"), atomically: true, encoding: .utf8)

        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.backupOriginalSignature(appURL: portal, bundleIdentifier: stubIdentifier)

        let backupData = try Data(contentsOf: workspace.backups.appendingPathComponent(identifier + ".plist"))
        let backup = try #require(try PropertyListSerialization.propertyList(from: backupData, format: nil) as? [String: Any])
        #expect(backup["bundleIdentifier"] as? String == identifier)
        #expect(backup["originalPath"] as? String == realApp.path)
        #expect(FileManager.default.fileExists(atPath: workspace.backups.appendingPathComponent(stubIdentifier + ".plist").path) == false)
    }

    @Test("Signing unlocks nested files even when the bundle root is not locked")
    func signingPreservesMixedFlags() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Mixed Locks.app")
        try makeBundle(at: app)
        let helper = app.appendingPathComponent("Contents/Helpers/Helper.app")
        try makeBundle(at: helper, identifier: "com.appports.tests.helper")
        try codesign(["--force", "--deep", "--sign", "-", app.path])
        let main = app.appendingPathComponent("Contents/MacOS/Fixture")
        let helperExecutable = helper.appendingPathComponent("Contents/MacOS/Fixture")
        try setFlags(UInt32(UF_IMMUTABLE | UF_HIDDEN), at: main)
        try setFlags(UInt32(UF_IMMUTABLE), at: helperExecutable)
        try setFlags(UInt32(UF_IMMUTABLE), at: app.appendingPathComponent("Contents/Helpers"))
        let before = try allFlags(in: app)
        try #require(before[app.path] == 0)

        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.sign(appURL: app, bundleIdentifier: nil)

        #expect(await signer.verify(appURL: app) == .valid)
        #expect(await signer.verify(appURL: helper) == .valid)
        #expect(try allFlags(in: app) == before)
    }

    @Test("Read-only code and resources can be signed without changing their permissions or unrelated metadata")
    func signingAllowsReadOnlyFiles() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Read Only.app")
        try makeBundle(at: app)
        let main = app.appendingPathComponent("Contents/MacOS/Fixture")
        let info = app.appendingPathComponent("Contents/Info.plist")
        let resources = app.appendingPathComponent("Contents/Resources")
        let payload = resources.appendingPathComponent("payload.txt")
        let detritusFile = resources.appendingPathComponent("metadata.bin")
        try Data("read-only resource".utf8).write(to: payload)
        try Data("resource with a fork".utf8).write(to: detritusFile)
        let metadata = Data("preserve this attribute".utf8)
        let attribute = "com.appports.tests.metadata"
        try #require(metadata.withUnsafeBytes {
            setxattr(app.path, attribute, $0.baseAddress, $0.count, 0, 0)
        } == 0)
        let resourceFork = Data("unsealed resource fork".utf8)
        try #require(resourceFork.withUnsafeBytes {
            setxattr(detritusFile.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
        } == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: main.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: info.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: payload.path)

        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.backupOriginalSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        try await signer.sign(appURL: app, bundleIdentifier: nil)

        #expect(await signer.verify(appURL: app) == .valid)
        #expect((try FileManager.default.attributesOfItem(atPath: main.path))[.posixPermissions] as? Int == 0o555)
        #expect((try FileManager.default.attributesOfItem(atPath: info.path))[.posixPermissions] as? Int == 0o444)
        #expect((try FileManager.default.attributesOfItem(atPath: payload.path))[.posixPermissions] as? Int == 0o444)
        #expect(getxattr(app.path, attribute, nil, 0, 0, 0) == metadata.count)
        #expect(getxattr(detritusFile.path, "com.apple.ResourceFork", nil, 0, 0, 0) == -1)
        #expect(errno == ENOATTR)
        try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        #expect(try readAttribute("com.apple.ResourceFork", at: detritusFile) == resourceFork)
        #expect(try readAttribute(attribute, at: app) == metadata)
    }

    @Test("Entitlements are read from the signed bundle and the sandbox flag is detected")
    func readsEntitlements() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let sandboxed = workspace.root.appendingPathComponent("Sandboxed.app")
        try makeBundle(at: sandboxed, identifier: "com.appports.tests.sandboxed")
        let sandboxEntitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", sandboxEntitlements.path, sandboxed.path])
        let plain = workspace.root.appendingPathComponent("Plain.app")
        try makeBundle(at: plain, identifier: "com.appports.tests.plain")
        try codesign(["--force", "--sign", "-", plain.path])
        let unsigned = workspace.root.appendingPathComponent("Unsigned.app")
        try makeBundle(at: unsigned, identifier: "com.appports.tests.unsigned")
        // The arm64 fixture binary carries the linker's embedded ad-hoc
        // signature. Remove it only from this temporary copy to test truly
        // unsigned code, rather than signed code without entitlements.
        try codesign(["--remove-signature", unsigned.path])

        #expect(CodeSigner.entitlements(at: sandboxed)?["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(CodeSigner.isSandboxed(at: sandboxed))
        #expect(CodeSigner.isSandboxed(at: plain) == false)
        #expect(CodeSigner.isSandboxed(at: unsigned) == false)
        #expect(CodeSigner.sandboxStatus(at: unsigned) == .unsigned)
        #expect(CodeSigner.entitlements(at: unsigned) == nil)
    }

    @Test("Sandboxed applications are refused before the bundle or backups are modified")
    func refusesSandboxedApplication() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat.app")
        try makeBundle(at: realApp, identifier: "com.appports.tests.sandboxed-chat")
        let sandboxEntitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", sandboxEntitlements.path, realApp.path])
        let portal = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: portal, identifier: "com.appports.tests.sandboxed-chat.appports.stub")
        try realApp.path.write(to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"), atomically: true, encoding: .utf8)
        let executable = realApp.appendingPathComponent("Contents/MacOS/Fixture")
        let original = try Data(contentsOf: executable)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })

        do {
            try await signer.sign(appURL: portal, bundleIdentifier: nil)
            Issue.record("A sandboxed application must never be ad-hoc re-signed")
        } catch CodeSigner.SigningError.sandboxedApplication(let url) {
            #expect(url.path == realApp.path)
        }

        #expect(try Data(contentsOf: executable) == original)
        #expect(CodeSigner.isSandboxed(at: realApp))
        #expect(FileManager.default.fileExists(atPath: workspace.backups.path) == false)
    }

    @Test("Ordinary data migration completes without touching the real sandbox app signature")
    func ordinaryDataMigrationPreservesSandboxSignature() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat.app")
        try makeBundle(at: realApp, identifier: "com.appports.tests.data-sandbox")
        let entitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, realApp.path])
        let portal = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: portal, identifier: "com.appports.tests.data-sandbox.appports.stub")
        try realApp.path.write(to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"), atomically: true, encoding: .utf8)
        let dataDirectory = workspace.root.appendingPathComponent("Library/Application Support/Chat")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let dataFile = dataDirectory.appendingPathComponent("state.txt")
        let originalData = Data("original application data".utf8)
        try originalData.write(to: dataFile)
        let originalApp = try SignatureSnapshot.fingerprint(of: realApp)
        #expect(CodeSigner.isSandboxed(at: portal) == false)

        let destination = workspace.root.appendingPathComponent("External/ChatData")
        try await DataMigrationWorkflow.run(migrate: {
            try FileManager.default.moveItem(at: dataDirectory, to: destination)
            try FileManager.default.createSymbolicLink(at: dataDirectory, withDestinationURL: destination)
        })

        #expect(try Data(contentsOf: dataFile) == originalData)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dataDirectory.path) == destination.path)
        #expect(try SignatureSnapshot.fingerprint(of: realApp) == originalApp)
        #expect(CodeSigner.isSandboxed(at: realApp))
        #expect(!FileManager.default.fileExists(atPath: workspace.backups.path))
    }

    @Test("Signature-replaced classification reads developer and ad-hoc backup identities")
    func signatureReplacedDetection() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let identifier = "com.appports.tests.replaced"
        let backupURL = workspace.backups.appendingPathComponent(identifier + ".plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "bundleIdentifier": identifier,
            "signingIdentity": "Developer ID Application: Nobody (APPPORTS00)",
            "originalPath": "/Applications/Nobody.app",
            "backupDate": Date()
        ], format: .xml, options: 0).write(to: backupURL)

        let original = CodeSigner.originalSigningIdentity(bundleIdentifier: identifier, backupDirectoryURL: workspace.backups)
        #expect(original == "Developer ID Application: Nobody (APPPORTS00)")
        #expect(CodeSigner.isSignatureReplaced(originalIdentity: original, currentlyAdHoc: true))
        #expect(CodeSigner.isSignatureReplaced(originalIdentity: original, currentlyAdHoc: false) == false)
        #expect(CodeSigner.isSignatureReplaced(originalIdentity: "ad-hoc", currentlyAdHoc: true) == false)
        #expect(CodeSigner.isSignatureReplaced(originalIdentity: nil, currentlyAdHoc: true) == false)

        // Still ad-hoc: the backup must survive so the repair flow can find the app later.
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        // Developer signatures also occur between pre-backup and re-sign: scanning must preserve the record.
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(CodeSigner.originalSigningIdentity(bundleIdentifier: identifier, backupDirectoryURL: workspace.backups) == original)
    }

    @Test("Classic mode can opt in to re-signing a sandboxed application")
    func classicModeAllowsSandboxedResign() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Classic.app")
        try makeBundle(at: app, identifier: "com.appports.tests.classic")
        let sandboxEntitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", sandboxEntitlements.path, app.path])
        try #require(CodeSigner.isSandboxed(at: app))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })

        try await signer.sign(appURL: app, bundleIdentifier: nil, allowSandboxed: true)

        #expect(await signer.verify(appURL: app) == .valid)
        #expect(await !signer.hasBackup(bundleIdentifier: "com.appports.tests.classic"))
        #expect(try SignatureFactStore(backupDirectoryURL: workspace.backups).currentFact(at: app) != nil)
    }

    @Test("Legacy identity-only backups never pretend to restore signed or unsigned state", arguments: ["Developer ID Application: Nobody (APPPORTS00)", "ad-hoc"])
    func restoreRefusesMissingIdentity(identity: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        let identifier = "com.appports.tests.restore-chat"
        try makeBundle(at: app, identifier: identifier)
        try codesign(["--force", "--sign", "-", app.path])
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let backupURL = workspace.backups.appendingPathComponent(identifier + ".plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "bundleIdentifier": identifier,
            "signingIdentity": identity,
            "originalPath": app.path,
            "backupDate": Date()
        ], format: .xml, options: 0).write(to: backupURL)
        let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
        let original = try Data(contentsOf: executable)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })

        do {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: identifier)
            Issue.record("Restoring without the original certificate must fail")
        } catch CodeSigner.SigningError.legacyBackupIncomplete {
            // Neither an authority name nor an ad-hoc label contains the original signature bytes.
        }

        #expect(try Data(contentsOf: executable) == original)
        #expect(FileManager.default.fileExists(atPath: backupURL.path), "The backup must survive a refused restore")
        #expect(await signer.hasBackup(bundleIdentifier: identifier))
    }

    @Test("Signing failure restores locks and leaves linked external data untouched")
    func failureRestoresLocksWithoutFollowingLinks() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Invalid.app")
        try makeBundle(at: app)
        let main = app.appendingPathComponent("Contents/MacOS/Fixture")
        try Data("invalid Mach-O".utf8).write(to: main)
        let outside = workspace.root.appendingPathComponent("ExternalData")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let payload = outside.appendingPathComponent("payload.txt")
        let originalData = Data("unchanged external data".utf8)
        try originalData.write(to: payload)
        let attribute = "com.appports.tests.external-data"
        try #require(originalData.withUnsafeBytes {
            setxattr(payload.path, attribute, $0.baseAddress, $0.count, 0, 0)
        } == 0)
        try setFlags(UInt32(UF_IMMUTABLE), at: outside)
        try setFlags(UInt32(UF_IMMUTABLE | UF_HIDDEN), at: payload)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/Resources/external-data"), withDestinationURL: outside)
        try setFlags(UInt32(UF_IMMUTABLE), at: app)
        try setFlags(UInt32(UF_IMMUTABLE), at: main)
        let before = try allFlags(in: app)
        let outsideBefore = try allFlags(in: outside)

        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        do {
            try await signer.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("Malformed code must fail signing")
        } catch CodeSigner.SigningError.codesignFailed {
            // The source remains intact even when signing rejects malformed code.
        } catch CodeSigner.SigningError.entitlementsUnavailable {
            // Unreadable authorization is rejected before mutating the original.
        }

        for (path, flags) in before {
            #expect(try fileFlags(at: URL(fileURLWithPath: path)) == flags)
        }
        #expect(try allFlags(in: outside) == outsideBefore)
        #expect(try Data(contentsOf: payload) == originalData)
        #expect(getxattr(payload.path, attribute, nil, 0, 0, 0) == originalData.count)
    }

    @Test("Existing complete originals restore unsigned and sandboxed ad-hoc apps byte for byte", arguments: [false, true])
    func snapshotRoundTrip(sandboxed: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Original.app")
        let helper = app.appendingPathComponent("Contents/Helpers/Helper.app")
        try makeBundle(at: app)
        try makeBundle(at: helper, identifier: "com.appports.tests.helper")
        let entitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, helper.path])
        if sandboxed {
            try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, app.path])
        } else {
            try codesign(["--remove-signature", app.path])
        }
        try Data("original resource".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/link").path, withDestinationPath: "data.txt")
        if sandboxed { try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, app.path]) }
        let before = try SignatureSnapshot.fingerprint(of: app)
        let helperBytes = try Data(contentsOf: helper.appendingPathComponent("Contents/MacOS/Fixture"))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.backupOriginalSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        try await signer.sign(appURL: app, bundleIdentifier: nil, allowSandboxed: true)
        #expect(CodeSigner.isSandboxed(at: app) == false)
        try await signer.sign(appURL: app, bundleIdentifier: nil, allowSandboxed: true)

        // 移动过应用也能恢复，不能依赖备份中的旧绝对路径。
        let moved = workspace.root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: app, to: moved)
        let restored = try await signer.restoreSignature(appURL: moved, bundleIdentifier: "com.appports.tests.fixture")
        #expect(restored.cleanupWarning == nil)
        #expect(try SignatureSnapshot.fingerprint(of: moved) == before)
        #expect(try Data(contentsOf: moved.appendingPathComponent("Contents/Helpers/Helper.app/Contents/MacOS/Fixture")) == helperBytes)
        #expect(CodeSigner.isSandboxed(at: moved) == sandboxed)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture") == false)
    }

    @Test("Real certificate originals survive repeated signing and relocation until official recovery completes",
          .enabled(if: SignedTestApplication.source != nil))
    func restoresCertificateSignedApplication() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        // 真实 CMS 签名的应用；只读源程序，所有变更都在测试副本里。
        let source = try #require(SignedTestApplication.source)
        let app = workspace.root.appendingPathComponent("Vendor.app")
        try SignatureSnapshot.copy(from: source, to: app)
        let identifier = try #require(CodeSigner.bundleIdentifier(at: app))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        let authority = try #require(await signer.getSigningIdentity(appURL: app))
        try codesign(["--verify", "--deep", app.path])
        let originalVerification = await signer.verify(appURL: app)
        try #require(originalVerification == .valid)
        let original = try SignatureSnapshot.fingerprint(of: app)
        let entitlements = CodeSigner.entitlements(at: app) as NSDictionary?
        let sourceIdentity = try DataPathIdentity.capture(source)
        let sourceFingerprint = try SignatureSnapshot.fingerprint(of: source)
        let facts = SignatureFactStore(backupDirectoryURL: workspace.backups)

        try await signer.sign(appURL: app, bundleIdentifier: identifier, allowSandboxed: true)
        #expect(await signer.getSigningIdentity(appURL: app) == nil)
        let first = try #require(try facts.currentFact(at: app, verifyContent: true))
        #expect(first.originalDeveloper?.authority == authority)
        #expect(first.signatureWasReplaced)
        try await signer.sign(appURL: app, bundleIdentifier: identifier)
        let second = try #require(try facts.currentFact(at: app, verifyContent: true))
        #expect(second.installationID == first.installationID)
        #expect(second.originalDeveloper == first.originalDeveloper)
        #expect(second.originalFingerprint == original)
        #expect(try facts.facts().count == 1)
        #expect(await signer.hasBackup(bundleIdentifier: identifier))
        let retained = try #require(try SignatureHistoryStore(backupDirectoryURL: workspace.backups).read(bundleIdentifier: identifier))
        #expect(retained.originalFingerprint == original)

        let other = workspace.root.appendingPathComponent("IndependentInstallation.app")
        try SignatureSnapshot.copy(from: app, to: other)
        let otherFingerprint = try SignatureSnapshot.fingerprint(of: other)
        #expect(try facts.currentFact(at: other) == nil)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await signer.restoreSignature(appURL: other, bundleIdentifier: identifier, originalApplication: source)
        }
        #expect(try SignatureSnapshot.fingerprint(of: other) == otherFingerprint)

        let relocation = try #require(try facts.captureRelocation(from: app))
        let moved = workspace.root.appendingPathComponent("External/Vendor.app")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SignatureSnapshot.copy(from: app, to: moved)
        try SignatureSnapshot.remove(app)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: moved)
        try facts.commitRelocation(relocation, to: moved)
        #expect(try facts.currentFact(at: moved, verifyContent: true)?.installationID == first.installationID)

        try await signer.restoreSignature(appURL: app, bundleIdentifier: identifier, originalApplication: source)

        try codesign(["--verify", "--deep", "--strict", moved.path])
        #expect(await signer.verify(appURL: app) == originalVerification)
        #expect(await signer.getSigningIdentity(appURL: app) == authority)
        #expect(try SignatureSnapshot.fingerprint(of: moved) == original)
        #expect(CodeSigner.entitlements(at: moved) as NSDictionary? == entitlements)
        #expect(try facts.currentFact(at: moved, verifyContent: true)?.signatureWasReplaced == false)
        #expect(await !signer.hasBackup(bundleIdentifier: identifier))
        #expect(try await signer.signatureMaterials().isEmpty)
        #expect(try DataPathIdentity.capture(source).matchesFilesystemObject(sourceIdentity))
        #expect(try SignatureSnapshot.fingerprint(of: source) == sourceFingerprint)
    }

    @Test("Changed applications cannot be overwritten or paired with an older snapshot")
    func refusesChangesSinceSigning() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.backupOriginalSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        let changed = app.appendingPathComponent("Contents/Resources/new-version.txt")
        try Data("new app content".utf8).write(to: changed)
        let before = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
            Issue.record("A restore must not overwrite updates")
        } catch CodeSigner.SigningError.applicationChanged {}
        let oldRecord = try Data(contentsOf: workspace.backups.appendingPathComponent("com.appports.tests.fixture.plist"))
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        #expect(try String(contentsOf: changed, encoding: .utf8) == "new app content")
        #expect(try Data(contentsOf: workspace.backups.appendingPathComponent("com.appports.tests.fixture.plist")) == oldRecord)
        #expect(try SignatureSnapshot.fingerprint(of: app) != before)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture"))
    }

    @Test("An app update during work-copy creation never becomes restorable from the old snapshot")
    func refusesUpdateDuringSigningCopy() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let original = try SignatureSnapshot.fingerprint(of: app)
        let changed = app.appendingPathComponent("Contents/Resources/update.txt")
        let fixtureWriter = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                       recoveryDependencyCheck: { _ in })
        try await fixtureWriter.backupOriginalSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) },
            copyApplication: { source, destination in
                if destination.deletingLastPathComponent().lastPathComponent.hasPrefix(".AppPorts-signature-") {
                    try Data("updated while preparing signature".utf8).write(to: changed)
                }
                try SignatureSnapshot.copyContents(from: source, into: destination)
            })
        do {
            try await signer.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("The copied update must not be signed against the old backup")
        } catch CodeSigner.SigningError.applicationChanged {}
        #expect(try String(contentsOf: changed, encoding: .utf8) == "updated while preparing signature")
        let record = try readBackup(in: workspace, identifier: "com.appports.tests.fixture")
        #expect(record["restorableFingerprints"] as? [String] == [original])
        #expect(try SignatureSnapshot.fingerprint(of: app) != original)
    }

    @Test("Restoration restores metadata even when the content digest has not changed")
    func restoresMetadataWithIdenticalContent() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let attribute = "com.appports.tests.metadata"
        let original = Data("original metadata".utf8)
        try #require(original.withUnsafeBytes { setxattr(app.path, attribute, $0.baseAddress, $0.count, 0, 0) } == 0)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.backupOriginalSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        let before = try SignatureSnapshot.fingerprint(of: app)
        try #require(removexattr(app.path, attribute, 0) == 0)
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        #expect(try readAttribute(attribute, at: app) == original)
    }

    @Test("A verified official reinstall retains its current original and retires only authenticated old backups",
          .enabled(if: SignedTestApplication.source != nil),
          arguments: [false, true])
    func renewsBackupAfterOfficialReinstall(legacy: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try #require(SignedTestApplication.source)
        let app = workspace.root.appendingPathComponent("Vendor.app")
        try SignatureSnapshot.copy(from: source, to: app)
        let identifier = try #require(CodeSigner.bundleIdentifier(at: app))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.backupOriginalSignature(appURL: app, bundleIdentifier: identifier)
        try await signer.sign(appURL: app, bundleIdentifier: identifier, allowSandboxed: true)
        var oldRecord = try readBackup(in: workspace, identifier: identifier)
        let oldSnapshot = workspace.backups.appendingPathComponent(try #require(oldRecord["snapshotName"] as? String))
        if legacy {
            for key in ["schemaVersion", "snapshotName", "originalFingerprint", "restorableFingerprints", "originalSignatureWasValid"] {
                oldRecord.removeValue(forKey: key)
            }
            try PropertyListSerialization.data(fromPropertyList: oldRecord, format: .xml, options: 0)
                .write(to: workspace.backups.appendingPathComponent(identifier + ".plist"))
        }
        try SignatureSnapshot.remove(app)
        try SignatureSnapshot.copy(from: source, to: app)
        // 安装器可能改变目录权限；新内容摘要不能与旧快照混用，官方签名仍须严格有效。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.path)
        try #require(await signer.verify(appURL: app) == .valid)
        let reinstalled = try SignatureSnapshot.fingerprint(of: app)
        try #require((oldRecord["restorableFingerprints"] as? [String])?.contains(reinstalled) != true)
        try await signer.sign(appURL: app, bundleIdentifier: identifier, allowSandboxed: true)
        let fact = try #require(try SignatureFactStore(backupDirectoryURL: workspace.backups).currentFact(at: app))
        let history = SignatureHistoryStore(backupDirectoryURL: workspace.backups)
        let newRecordURL = URL(fileURLWithPath: try #require(fact.legacyBackupRecordPath))
        let newRecord = try history.read(at: newRecordURL)
        #expect(newRecord.originalFingerprint == reinstalled)
        #expect(try SignatureSnapshot.fingerprint(of: history.verifiedSnapshot(for: newRecord)) == reinstalled)
        #expect(FileManager.default.fileExists(atPath: oldSnapshot.path) == legacy)
        if legacy {
            #expect(try readBackup(in: workspace, identifier: identifier) as NSDictionary == oldRecord as NSDictionary)
            #expect(newRecordURL.deletingLastPathComponent().lastPathComponent == "retired")
        }
        #expect(fact.originalFingerprint == reinstalled)
        let restored = try await signer.restoreSignature(appURL: app, bundleIdentifier: identifier)
        #expect(restored.cleanupWarning == nil)
        #expect(try SignatureSnapshot.fingerprint(of: app) == reinstalled)
        #expect(!FileManager.default.fileExists(atPath: newRecordURL.path))
        #expect(await signer.verify(appURL: app) == .valid)
    }

    @Test("Corrupt snapshots leave the current application and recovery record untouched")
    func refusesCorruptSnapshot() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.backupOriginalSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        let snapshot = try #require(try FileManager.default.contentsOfDirectory(at: workspace.backups, includingPropertiesForKeys: nil).first { $0.pathExtension == "app" })
        try Data("corrupt".utf8).write(to: snapshot.appendingPathComponent("Contents/MacOS/Fixture"))
        let before = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
            Issue.record("A corrupt snapshot must not be restored")
        } catch CodeSigner.SigningError.snapshotInvalid {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture"))
    }

    @Test("Failed exchanges preserve both application and backup and allow retry")
    func exchangeFailureIsRecoverable() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        let failing = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) },
            exchangeApplications: { _, _ in throw CodeSigner.SigningError.atomicReplacementUnavailable })
        let original = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await failing.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("Forced sign exchange must fail")
        } catch CodeSigner.SigningError.atomicReplacementUnavailable {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == original)
        try await signer.backupOriginalSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        let signed = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await failing.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
            Issue.record("Forced restore exchange must fail")
        } catch CodeSigner.SigningError.atomicReplacementUnavailable {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == signed)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture"))
        try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        #expect(try SignatureSnapshot.fingerprint(of: app) == original)
    }

    @Test("An identity-only record cannot certify an ad-hoc selected original as official")
    func restoresLegacyBackupFromOriginal() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let original = workspace.root.appendingPathComponent("Original.app")
        let app = workspace.root.appendingPathComponent("Installed.app")
        try makeBundle(at: original)
        let entitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, original.path])
        try SignatureSnapshot.copy(from: original, to: app)
        try codesign(["--force", "--sign", "-", app.path])
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let identifier = "com.appports.tests.fixture"
        try PropertyListSerialization.data(fromPropertyList: [
            "bundleIdentifier": identifier, "signingIdentity": "ad-hoc",
            "originalPath": app.path, "backupDate": Date()
        ], format: .xml, options: 0).write(to: workspace.backups.appendingPathComponent(identifier + ".plist"))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        let before = try SignatureSnapshot.fingerprint(of: app)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: identifier, originalApplication: original)
        }
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        #expect(!CodeSigner.isSandboxed(at: app))
    }

    @Test("Different CodeSigner instances share a filesystem transaction lock")
    func preventsConcurrentSigningInstances() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let lock = OperationLock(fileURL: workspace.backups.appendingPathComponent("signature-operation.lock"))
        try #require(lock.tryAcquire())
        defer { lock.release() }
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        let before = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await signer.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("Another signing transaction holds the lock")
        } catch let error as OperationBlockage {
            #expect(error.reason == .signatureLockBusy)
            #expect(error.applicationURL?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path)
            #expect(error.diagnosticFields["lock_owner"] == "unknown")
        }
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
    }

    @Test("A selected original must match the installed app identity and version", arguments: ["CFBundleIdentifier", "CFBundleVersion"])
    func rejectsMismatchedOriginal(key: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Installed.app")
        let original = workspace.root.appendingPathComponent("Wrong.app")
        try makeBundle(at: app)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
                                trashBackupSnapshot: { try SignatureSnapshot.remove($0) }, recoveryDependencyCheck: { _ in })
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        try SignatureSnapshot.copy(from: app, to: original)
        let info = original.appendingPathComponent("Contents/Info.plist")
        var plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        plist[key] = "wrong"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        try codesign(["--force", "--sign", "-", original.path])
        let before = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture", originalApplication: original)
            Issue.record("A different app or version must not replace the installed app")
        } catch CodeSigner.SigningError.originalApplicationMismatch {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        #expect(await !signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture"))
    }

    @Test("Refreshing an installed re-sign script preserves the old script if the source is missing")
    func refreshInstalledResignScript() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = workspace.root.appendingPathComponent("Bundled.sh")
        let installed = workspace.root.appendingPathComponent("Installed.sh")
        try Data("old script".utf8).write(to: installed)
        #expect(throws: (any Error).self) {
            try AutoResignInstaller.synchronizeScript(from: source, to: installed)
        }
        #expect(try String(contentsOf: installed, encoding: .utf8) == "old script")
        try Data("new script".utf8).write(to: source)
        try AutoResignInstaller.synchronizeScript(from: source, to: installed)
        #expect(try String(contentsOf: installed, encoding: .utf8) == "new script")
        #expect(try FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions] as? Int == 0o755)
    }

    private struct Workspace {
        let root: URL
        var backups: URL { root.appendingPathComponent("SignatureBackups") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppPortsCodeSignerTests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func cleanup() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
            process.arguments = ["-R", "nouchg", root.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func readBackup(in workspace: Workspace, identifier: String) throws -> [String: Any] {
        let data = try Data(contentsOf: workspace.backups.appendingPathComponent(identifier + ".plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func readAttribute(_ name: String, at url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        try #require(size >= 0)
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        try #require(read == size)
        return data
    }

    private func makeBundle(at url: URL, identifier: String = "com.appports.tests.fixture") throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let binary = try #require(Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil))
        let executable = url.appendingPathComponent("Contents/MacOS/Fixture")
        try fileManager.copyItem(at: binary, to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                    "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func writeEntitlements(sandbox: Bool, in workspace: Workspace) throws -> URL {
        let url = workspace.root.appendingPathComponent("\(UUID().uuidString)-entitlements.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.app-sandbox": sandbox], format: .xml, options: 0
        ).write(to: url)
        return url
    }

    private func setFlags(_ flags: UInt32, at url: URL) throws {
        try #require(lchflags(url.path, flags) == 0)
    }

    private func fileFlags(at url: URL) throws -> UInt32 {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info.st_flags
    }

    private func allFlags(in root: URL) throws -> [String: UInt32] {
        var result = [root.path: try fileFlags(at: root)]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            result[url.path] = try fileFlags(at: url)
        }
        return result
    }

    private func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(String(decoding: output, as: UTF8.self))")
    }
}

@Suite("Data migration independent completion")
struct DataMigrationWorkflowTests {
    private enum Failure: Error { case validation, migration }

    @Test("Validation prevents mutation and preserves its error")
    func validationFailureStopsBeforeMigration() async {
        let calls = Calls()
        await #expect(throws: Failure.validation) {
            try await DataMigrationWorkflow.run(
                validateBeforeMigration: { throw Failure.validation },
                migrate: { await calls.append("migrate") }
            )
        }
        #expect(await calls.values.isEmpty)
    }

    @Test("Migration errors stay migration errors")
    func migrationFailureIsNotWrappedAsSigningFailure() async {
        await #expect(throws: Failure.migration) {
            try await DataMigrationWorkflow.run(migrate: { throw Failure.migration })
        }
    }

    @Test("Cancellation before mutation cannot start a new transfer")
    func cancellationBeforeMutation() async {
        let calls = Calls()
        let task = Task {
            try await DataMigrationWorkflow.run(
                validateBeforeMigration: { withUnsafeCurrentTask { $0?.cancel() } },
                migrate: { await calls.append("migrate") }
            )
        }
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(await calls.values.isEmpty)
    }

    @Test("A completed data switch returns its cleanup result unchanged")
    func returnsCommittedCleanupWarning() async throws {
        let result = try await DataMigrationWorkflow.run {
            DataDirMover.CompletionResult(cleanupWarning: "Old copy is still in use")
        }
        #expect(result.cleanupWarning == "Old copy is still in use")
    }

    private actor Calls {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }
}
