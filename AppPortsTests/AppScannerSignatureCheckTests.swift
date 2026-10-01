//
//  AppScannerSignatureCheckTests.swift
//  AppPorts
//
//  启动时的「签名已被替换」快检：不依赖完整扫描，只查签名备份目录。
//

import Foundation
import Testing
@testable import AppPorts

@Suite("Launch signature check")
struct AppScannerSignatureCheckTests {

    private static let developerIdentity = "Developer ID Application: Example Corp (AAAA111111)"

    @Test("只报告原始签名非 ad-hoc、当前仍是 ad-hoc 的应用")
    func reportsOnlyReplacedApps() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()

        // 备份记的是开发者证书，当前是 ad-hoc → 应报告
        let replaced = try workspace.makeApp(in: root, named: "Replaced.app", identifier: "com.appports.tests.replaced", adHoc: true)
        try workspace.writeBackup(bundleID: "com.appports.tests.replaced", identity: Self.developerIdentity, originalPath: replaced.path)

        // 备份的原始身份本来就是 ad-hoc（例如 AppPorts 生成的 stub）→ 不报告
        let adHocOrigin = try workspace.makeApp(in: root, named: "AdHocOrigin.app", identifier: "com.appports.tests.adhoc", adHoc: true)
        try workspace.writeBackup(bundleID: "com.appports.tests.adhoc", identity: "ad-hoc", originalPath: adHocOrigin.path)

        // 没有备份 → 不报告
        _ = try workspace.makeApp(in: root, named: "Untouched.app", identifier: "com.appports.tests.untouched", adHoc: true)

        let scanner = AppScanner(backupDirectoryURL: workspace.backups)
        let result = await scanner.signatureReplacedApps(searchRoots: [root])

        #expect(result.map(\.displayName) == ["Replaced.app"])
        #expect(result.map(\.dismissalKey) == [replaced.standardizedFileURL.path])
    }

    @Test("已迁移到外部库的 stub 也认得出来")
    func detectsStubPortal() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()
        let external = workspace.root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let realApp = try workspace.makeApp(in: external, named: "Mole.app", identifier: "com.appports.tests.mole", adHoc: true)
        let stub = try workspace.makeApp(in: root, named: "Mole.app", identifier: "com.appports.tests.mole.appports.stub", adHoc: false)
        try (realApp.path + "\n").write(
            to: stub.appendingPathComponent("Contents/Resources/real_app_path.txt"),
            atomically: true, encoding: .utf8
        )
        // 备份挂在真实应用的 bundle ID 下，本地只剩 stub
        try workspace.writeBackup(bundleID: "com.appports.tests.mole", identity: Self.developerIdentity, originalPath: realApp.path)

        let scanner = AppScanner(backupDirectoryURL: workspace.backups)
        let result = await scanner.signatureReplacedApps(searchRoots: [root])

        #expect(result.map(\.displayName) == ["Mole.app"])
        #expect(result.map(\.dismissalKey) == [stub.standardizedFileURL.path])
    }

    @Test("开发者签名状态不报告风险，也不删除预备份恢复材料")
    func keepsBackupWhenDeveloperSignatureIsPresent() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()

        // 主可执行是 Apple 签名的系统二进制，对 codesign 而言不是 ad-hoc，等价于「签名已恢复」
        let restored = try workspace.makeApp(in: root, named: "Restored.app", identifier: "com.appports.tests.restored", adHoc: false)
        try workspace.writeBackup(bundleID: "com.appports.tests.restored", identity: Self.developerIdentity, originalPath: restored.path)

        let scanner = AppScanner(backupDirectoryURL: workspace.backups)
        let result = await scanner.signatureReplacedApps(searchRoots: [root])

        #expect(result.isEmpty)
        #expect(FileManager.default.fileExists(atPath: workspace.backups.appendingPathComponent("com.appports.tests.restored.plist").path))
    }

    @Test("已卸载的应用不出现在结果里")
    func skipsUninstalledApps() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()
        _ = try workspace.makeApp(in: root, named: "Present.app", identifier: "com.appports.tests.present", adHoc: true)
        try workspace.writeBackup(bundleID: "com.appports.tests.present", identity: Self.developerIdentity, originalPath: root.appendingPathComponent("Present.app").path)
        try workspace.writeBackup(bundleID: "com.appports.tests.gone", identity: Self.developerIdentity, originalPath: root.appendingPathComponent("Gone.app").path)

        let scanner = AppScanner(backupDirectoryURL: workspace.backups)
        let result = await scanner.signatureReplacedApps(searchRoots: [root])

        #expect(result.map(\.displayName) == ["Present.app"])
    }

    @Test("Repeated real signature probes retain their classification and backup")
    func repeatedActualSignatureProbesComplete() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()
        let identifier = "com.appports.tests.repeated-probe"
        let app = try workspace.makeApp(in: root, named: "Repeated.app", identifier: identifier, adHoc: true)
        try workspace.writeBackup(bundleID: identifier, identity: Self.developerIdentity, originalPath: app.path)
        let scanner = AppScanner(backupDirectoryURL: workspace.backups)
        for _ in 0..<12 {
            let status = await scanner.checkSigningStatus(bundleURL: app)
            #expect(status.isResigned)
            #expect(status.signatureReplaced)
            #expect(!status.signatureCheckUnavailable)
        }
        #expect(FileManager.default.fileExists(atPath: workspace.backups.appendingPathComponent(identifier + ".plist").path))
    }

    @Test("没有签名备份时直接返回空")
    func emptyWithoutBackups() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()
        _ = try workspace.makeApp(in: root, named: "Untouched.app", identifier: "com.appports.tests.untouched", adHoc: true)

        let scanner = AppScanner(backupDirectoryURL: workspace.backups)
        let result = await scanner.signatureReplacedApps(searchRoots: [root])

        #expect(result.isEmpty)
    }

    @Test("检查超时保留备份和待检查状态，不报告已替换或已恢复")
    func keepsBackupWhenSignatureProbeIsInconclusive() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()

        let app = try workspace.makeApp(in: root, named: "Slow.app", identifier: "com.appports.tests.slow", adHoc: true)
        try workspace.writeBackup(bundleID: "com.appports.tests.slow", identity: Self.developerIdentity, originalPath: app.path)

        // 外置盘繁忙不能成为签名被替换的证据，也不能删除恢复材料。
        let scanner = AppScanner(backupDirectoryURL: workspace.backups, adHocProbe: { _ in nil })
        let result = await scanner.signatureReplacedApps(searchRoots: [root])

        #expect(result.isEmpty)
        let apps = await scanner.scanLocalApps(at: root, runningAppURLs: [])
        let scanned = try #require(apps.first)
        #expect(scanned.signatureCheckUnavailable)
        #expect(scanned.needsSignatureAttention)
        #expect(!scanned.signatureReplaced)
        #expect(!scanned.isResigned)
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.backups.appendingPathComponent("com.appports.tests.slow.plist").path
            ),
            "查不出签名状态时删掉备份，用户就再也看不到修复入口了"
        )
    }

    @Test("codesign 读不出签名（非零退出）时同样保留备份")
    func keepsBackupWhenCodesignFails() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()

        let app = try workspace.makeBrokenApp(in: root, named: "Broken.app", identifier: "com.appports.tests.broken")
        try workspace.writeBackup(bundleID: "com.appports.tests.broken", identity: Self.developerIdentity, originalPath: app.path)

        let scanner = AppScanner(backupDirectoryURL: workspace.backups)
        let result = await scanner.signatureReplacedApps(searchRoots: [root])

        #expect(result.isEmpty)
        let status = await scanner.checkSigningStatus(bundleURL: app)
        #expect(status == .unavailable)
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.backups.appendingPathComponent("com.appports.tests.broken.plist").path
            )
        )
    }

    @Test("启动壳也有备份时仍只检查真实应用")
    func ignoresStubSignatureWhenBothHaveBackups() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()
        let external = workspace.root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let realApp = try workspace.makeApp(in: external, named: "Original.app", identifier: "com.appports.tests.original", adHoc: false)
        let stub = try workspace.makeApp(in: root, named: "Original.app", identifier: "com.appports.tests.original.appports.stub", adHoc: true)
        try (realApp.path + "\n").write(to: stub.appendingPathComponent("Contents/Resources/real_app_path.txt"), atomically: true, encoding: .utf8)
        try workspace.writeBackup(bundleID: "com.appports.tests.original", identity: Self.developerIdentity, originalPath: realApp.path)
        try workspace.writeBackup(bundleID: "com.appports.tests.original.appports.stub", identity: Self.developerIdentity, originalPath: stub.path)

        let scanner = AppScanner(backupDirectoryURL: workspace.backups)
        let result = await scanner.signatureReplacedApps(searchRoots: [root])
        #expect(result.isEmpty)
        let status = await scanner.checkSigningStatus(bundleURL: stub)
        #expect(status == .clean)
    }

    @Test("外置应用不可读时保留待检查入口，不检查本地启动壳")
    func keepsRecoveryEntryForUnavailableExternalApp() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let root = try workspace.makeSearchRoot()
        let missing = workspace.root.appendingPathComponent("Offline/Example.app")
        let stub = try workspace.makeApp(in: root, named: "Example.app", identifier: "com.appports.tests.offline.appports.stub", adHoc: true)
        try missing.path.write(to: stub.appendingPathComponent("Contents/Resources/real_app_path.txt"), atomically: true, encoding: .utf8)
        try workspace.writeBackup(bundleID: "com.appports.tests.offline", identity: Self.developerIdentity, originalPath: missing.path)

        let scanner = AppScanner(backupDirectoryURL: workspace.backups, adHocProbe: { _ in
            Issue.record("真实应用离线时不应探测启动壳的签名")
            return true
        })
        let status = await scanner.checkSigningStatus(bundleURL: stub)
        #expect(status == .unavailable)
        let result = await scanner.signatureReplacedApps(searchRoots: [root])
        #expect(result.isEmpty)
        #expect(FileManager.default.fileExists(atPath: workspace.backups.appendingPathComponent("com.appports.tests.offline.plist").path))
    }

    @Test("签名状态改变会触发应用列表刷新")
    func signatureStateAffectsEquality() {
        let original = AppItem(name: "Example.app", path: URL(fileURLWithPath: "/Applications/Example.app"), status: AppStatus.local)
        var changed = original
        changed.signatureCheckUnavailable = true
        #expect(original != changed)
        changed = original
        changed.signatureReplaced = true
        #expect(original != changed)
    }

    // MARK: - 夹具

    private struct Workspace {
        let root: URL
        var backups: URL { root.appendingPathComponent("SignatureBackups") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppPortsSignatureCheck-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func makeSearchRoot() throws -> URL {
            let applications = root.appendingPathComponent("Applications")
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            return applications
        }

        @discardableResult
        func makeApp(in directory: URL, named name: String, identifier: String, adHoc: Bool) throws -> URL {
            let app = directory.appendingPathComponent(name)
            // 主可执行统一用系统二进制（Apple 签名，本身不是 adhoc）；
            // adHoc 夹具在此基础上再显式 ad-hoc 重签名。
            try makeBundle(at: app, identifier: identifier, executableSource: URL(fileURLWithPath: "/bin/ls"))
            if adHoc {
                try codesign(["--force", "--sign", "-", app.path])
            }
            return app
        }

        /// codesign 会对它非零退出（可执行文件不是 Mach-O），用来覆盖「没查出来」的分支。
        @discardableResult
        func makeBrokenApp(in directory: URL, named name: String, identifier: String) throws -> URL {
            let app = directory.appendingPathComponent(name)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                        "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }

        func writeBackup(bundleID: String, identity: String, originalPath: String) throws {
            let record: [String: Any] = [
                "bundleIdentifier": bundleID,
                "signingIdentity": identity,
                "originalPath": originalPath,
                "backupDate": Date()
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
            try data.write(to: backups.appendingPathComponent("\(bundleID).plist"))
        }

        private func makeBundle(at url: URL, identifier: String, executableSource: URL) throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let executable = url.appendingPathComponent("Contents/MacOS/Fixture")
            try fileManager.copyItem(at: executableSource, to: executable)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                        "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
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
}
