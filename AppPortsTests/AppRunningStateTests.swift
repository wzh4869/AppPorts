import Foundation
import Testing
@testable import AppPorts

@Suite("Running application matching")
struct AppRunningStateTests {
    enum PortalKind: CaseIterable {
        case nativeStub, legacyStub, relativeAppLink, relativeContentsLink
    }

    @Test("Migrated portals detect the running real application", arguments: PortalKind.allCases)
    func detectsRealApplication(kind: PortalKind) throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat's.app")
        let portal = workspace.root.appendingPathComponent("Chat.app")
        let identifier = "com.appports.tests.chat"
        try makeBundle(at: realApp, identifier: identifier)

        switch kind {
        case .nativeStub:
            try makeBundle(at: portal, identifier: identifier + ".appports.stub")
            try realApp.path.write(
                to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"),
                atomically: true, encoding: .utf8
            )
        case .legacyStub:
            try makeBundle(at: portal, identifier: identifier + ".appports.stub")
            try FileManager.default.createDirectory(at: portal.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let escapedPath = realApp.path.replacingOccurrences(of: "'", with: "'\\''")
            try "#!/bin/bash\nREAL_APP='\(escapedPath)'\n".write(
                to: portal.appendingPathComponent("Contents/MacOS/launcher"),
                atomically: true, encoding: .utf8
            )
        case .relativeAppLink:
            try FileManager.default.createSymbolicLink(
                atPath: portal.path, withDestinationPath: "External/Chat's.app"
            )
        case .relativeContentsLink:
            try FileManager.default.createDirectory(at: portal, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: portal.appendingPathComponent("Contents").path,
                withDestinationPath: "../External/Chat's.app/Contents"
            )
        }

        // Each source of process identity must work independently.
        #expect(AppRunningState.isRunning(appURL: portal, applications: [
            .init(bundleURL: realApp, bundleIdentifier: nil)
        ]))
        #expect(AppRunningState.isRunning(appURL: portal, applications: [
            .init(bundleURL: nil, bundleIdentifier: identifier)
        ]))
        #expect(AppRunningState.isRunning(appURL: portal, applications: [
            .init(bundleURL: nil, bundleIdentifier: identifier + ".appports.stub")
        ]) == false)
    }

    @Test("Offline native stub portals match running external apps without accepting stub processes")
    func detectsOfflineNativeStubPortalTarget() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let offlineExternal = workspace.root.appendingPathComponent("MissingVolume/Chat.app")
        let portal = workspace.root.appendingPathComponent("Chat.app")
        let identifier = "com.appports.tests.offline.chat"
        try makeBundle(at: portal, identifier: identifier + ".appports.stub")
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleIdentifier": identifier + ".appports.stub",
            "AppPortsTargetBundleIdentifier": identifier
        ], format: .xml, options: 0).write(to: portal.appendingPathComponent("Contents/Info.plist"))
        try offlineExternal.path.write(
            to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"),
            atomically: true, encoding: .utf8
        )

        #expect(AppRunningState.isRunning(appURL: portal, applications: [
            .init(bundleURL: offlineExternal, bundleIdentifier: nil)
        ]))
        #expect(AppRunningState.isRunning(appURL: portal, applications: [
            .init(bundleURL: nil, bundleIdentifier: identifier)
        ]))
        #expect(AppRunningState.isRunning(appURL: portal, applications: [
            .init(bundleURL: nil, bundleIdentifier: identifier + ".appports.stub"),
            .init(bundleURL: portal, bundleIdentifier: nil)
        ]) == false)
    }

    @Test("Wrapped iOS apps resolve their Wrapper payload bundle identifier for running checks")
    func detectsRunningWrappedIOSApp() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let outer = workspace.root.appendingPathComponent("MobileGame.app")
        let inner = outer.appendingPathComponent("Wrapper/Payload.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.appports.tests.mobilegame",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: inner.appendingPathComponent("Info.plist"))

        #expect(AppRunningState.isRunning(appURL: outer, applications: [
            .init(bundleURL: nil, bundleIdentifier: "com.appports.tests.mobilegame")
        ]))
    }

    @Test("A running application URL can itself be a relative symlink")
    func resolvesRunningApplicationLink() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        let runningLink = workspace.root.appendingPathComponent("Running.app")
        try makeBundle(at: app, identifier: nil)
        try FileManager.default.createSymbolicLink(atPath: runningLink.path, withDestinationPath: "Chat.app")

        #expect(AppRunningState.isRunning(appURL: app, applications: [
            .init(bundleURL: runningLink, bundleIdentifier: nil)
        ]))
    }

    @Test("Missing bundle identifiers do not match unrelated processes")
    func ignoresMissingIdentifiers() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("No Identifier.app")
        let unrelated = workspace.root.appendingPathComponent("Unrelated.app")
        try makeBundle(at: app, identifier: nil)
        try makeBundle(at: unrelated, identifier: nil)

        #expect(AppRunningState.isRunning(appURL: app, applications: [
            .init(bundleURL: nil, bundleIdentifier: nil),
            .init(bundleURL: unrelated, bundleIdentifier: nil),
            .init(bundleURL: nil, bundleIdentifier: "")
        ]) == false)
        #expect(AppRunningState.isRunning(appURL: app, applications: [
            .init(bundleURL: app, bundleIdentifier: nil)
        ]))
    }

    @Test("Empty identifiers do not match without a matching path")
    func ignoresEmptyIdentifiers() {
        let app = URL(fileURLWithPath: "/Applications/Target.app")
        for identifier in ["", " ", "\n"] {
            #expect(AppRunningState.matches(
                appURL: app,
                bundleIdentifier: identifier,
                application: .init(bundleURL: nil, bundleIdentifier: identifier)
            ) == false)
        }
    }

    @Test("Different paths and identifiers are not the same application")
    func ignoresUnrelatedApplications() {
        #expect(AppRunningState.matches(
            appURL: URL(fileURLWithPath: "/Applications/Target.app"),
            bundleIdentifier: "com.appports.tests.target",
            application: .init(
                bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
                bundleIdentifier: "com.appports.tests.other"
            )
        ) == false)
    }

    private struct Workspace {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppPortsRunningStateTests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeBundle(at url: URL, identifier: String?) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        var info = ["CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        if let identifier { info["CFBundleIdentifier"] = identifier }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
}
