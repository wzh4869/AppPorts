import Foundation
import Testing
@testable import AppPorts

struct AppListTransferTests {
    @Test func movingOutUpdatesBothListsWithoutWaitingForScanner() {
        let app = AppItem(name: "Foo.app", path: URL(fileURLWithPath: "/Applications/Foo.app"),
                          status: AppStatus.local, version: "2.0", size: "8 MB", sizeBytes: 8_000_000)
        let destination = URL(fileURLWithPath: "/Volumes/Test/Apps/Foo.app")
        let unrelated = AppItem(name: "Other.app", path: URL(fileURLWithPath: "/Applications/Other.app"), status: AppStatus.local)
        var local = [app, unrelated]
        var external: [AppItem] = []
        let invalidated = AppListTransfer.movedOut(app, destination: destination, isMASExternal: false)
            .apply(localApps: &local, externalApps: &external)
        #expect(local.first?.status == AppStatus.linked)
        #expect(local.first?.size == nil)
        #expect(local.first?.sizeBytes == 0)
        #expect(local.last == unrelated)
        #expect(external.first?.path == destination)
        #expect(external.first?.status == AppStatus.linked)
        #expect(external.first?.sizeBytes == 8_000_000)
        #expect(external.first?.version == "2.0")
        #expect(invalidated == [app.id, destination.standardizedFileURL.path])
    }

    @Test func linkingInPreservesSignatureAndRebasesContainerBundle() {
        let source = URL(fileURLWithPath: "/Volumes/Test/Adobe")
        let app = AppItem(name: "Adobe", path: source, bundleURL: source.appendingPathComponent("Photoshop.app"),
                          status: AppStatus.unlinked, signatureReplaced: true, version: "26.0",
                          size: "3 GB", sizeBytes: 3_000_000_000, containerKind: .singleAppContainer, appCount: 1)
        let destination = URL(fileURLWithPath: "/Users/test/Applications/Adobe")
        var local: [AppItem] = []
        var external = [app]
        _ = AppListTransfer.linkedIn(app, localDestination: destination).apply(localApps: &local, externalApps: &external)
        #expect(local.first?.bundleURL?.path == "/Users/test/Applications/Adobe/Photoshop.app")
        #expect(local.first?.containerKind == .singleAppContainer)
        #expect(local.first?.signatureReplaced == true)
        #expect(local.first?.size == nil)
        #expect(external.count == 1)
        #expect(external.first?.status == AppStatus.linked)
        #expect(external.first?.sizeBytes == 3_000_000_000)
    }

    @Test(arguments: [true, false])
    func restoringReflectsWhetherExternalCleanupSucceeded(sourceRemains: Bool) {
        let source = URL(fileURLWithPath: "/Volumes/Test/Applications/Foo.app")
        let app = AppItem(name: "Foo.app", path: source, bundleURL: source, status: AppStatus.linked,
                          isAppStoreApp: true, isMASExternal: true, size: "8 MB", sizeBytes: 8_000_000)
        let destination = URL(fileURLWithPath: "/Custom/Applications/Foo.app")
        var local = [AppItem(name: "Foo.app", path: destination, status: AppStatus.linked)]
        var external = [app]
        _ = AppListTransfer.movedBack(app, localDestination: destination, externalSourceRemains: sourceRemains)
            .apply(localApps: &local, externalApps: &external)
        #expect(local.count == 1)
        #expect(local.first?.status == AppStatus.local)
        #expect(local.first?.isMASExternal == false)
        #expect(local.first?.isAppStoreApp == true)
        #expect(local.first?.path == destination)
        #expect(local.first?.sizeBytes == 8_000_000)
        #expect(external.count == (sourceRemains ? 1 : 0))
        if sourceRemains { #expect(external.first?.status == AppStatus.unlinked) }
    }

    @Test func replacingExistingExternalRowDoesNotDuplicateIt() {
        let destination = URL(fileURLWithPath: "/Volumes/Test/Applications/Foo.app")
        let app = AppItem(name: "Foo.app", path: URL(fileURLWithPath: "/Applications/Foo.app"),
                          status: AppStatus.pendingMoveOut, isAppStoreApp: true, version: "2")
        var local = [app]
        var external = [AppItem(name: "Foo.app", path: destination, status: AppStatus.unlinked, version: "1")]
        _ = AppListTransfer.movedOut(app, destination: destination, isMASExternal: true)
            .apply(localApps: &local, externalApps: &external)
        #expect(external.count == 1)
        #expect(external.first?.version == "2")
        #expect(external.first?.isMASExternal == true)
        #expect(local.first?.isMASExternal == false)
    }
}

extension AppListTransferTests {
    @Test(arguments: [false, true])
    func realMigrationOnlyPublishesSuccessfulTransfers(failPortal: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AppListTransfer-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let localURL = root.appendingPathComponent("Local/Foo.app")
        let destination = root.appendingPathComponent("External/Foo.app")
        let executable = localURL.appendingPathComponent("Contents/MacOS/Foo")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = ["CFBundleIdentifier": "com.appports.transfer.fixture", "CFBundleExecutable": "Foo",
                     "CFBundleName": "Foo", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: localURL.appendingPathComponent("Contents/Info.plist"))
        let service = AppMigrationService(portalCreationOverride: { app, external in
            if failPortal { throw NSError(domain: "AppListTransferTests", code: 1) }
            try fm.createSymbolicLink(at: app.path, withDestinationURL: external)
        }, dockShortcutUpdater: { _, _ in 0 })
        let app = AppItem(name: "Foo.app", path: localURL, bundleURL: localURL, status: AppStatus.local)
        var local = [app]
        var external: [AppItem] = []
        do {
            try await service.moveAndLink(appToMove: app, destinationURL: destination,
                                          isRunning: false, lockExternal: false, progressHandler: nil)
            AppListTransfer.movedOut(app, destination: destination, isMASExternal: false)
                .apply(localApps: &local, externalApps: &external)
            #expect(!failPortal)
        } catch {
            #expect(failPortal)
        }
        if failPortal {
            #expect(local == [app])
            #expect(external.isEmpty)
            #expect(fm.fileExists(atPath: executable.path))
            return
        }
        #expect(local.first?.status == AppStatus.linked)
        #expect(external.first?.status == AppStatus.linked)
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("Contents/MacOS/Foo").path))
        let moved = try #require(external.first)
        try await service.moveBack(app: moved, localDestinationURL: localURL, progressHandler: nil)
        AppListTransfer.movedBack(moved, localDestination: localURL,
                                  externalSourceRemains: fm.fileExists(atPath: destination.path))
            .apply(localApps: &local, externalApps: &external)
        #expect(local.first?.status == AppStatus.local)
        #expect(external.isEmpty)
        #expect(fm.fileExists(atPath: executable.path))
        #expect((try fm.attributesOfItem(atPath: localURL.path)[.type] as? FileAttributeType) == .typeDirectory)
    }
}

extension AppListTransferTests {
    @Test(arguments: [true, false])
    func restoredSuiteRemovesRetiredPortalsAndExternalChildren(sourceRemains: Bool) {
        let source = URL(fileURLWithPath: "/Volumes/Test/Office")
        let destination = URL(fileURLWithPath: "/Applications/Office")
        let retired = URL(fileURLWithPath: "/Applications/Word.app")
        let suite = AppItem(name: "Office", path: source, status: AppStatus.partialLinked,
                            isFolder: true, containerKind: .appSuiteFolder, appCount: 2)
        let unrelated = AppItem(name: "Other.app", path: URL(fileURLWithPath: "/Volumes/Test/Office Extra/Other.app"), status: AppStatus.unlinked)
        var local = [AppItem(name: "Word.app", path: retired, status: AppStatus.linked)]
        var external = [suite, AppItem(name: "Word.app", path: source.appendingPathComponent("Word.app"), status: AppStatus.linked), unrelated]
        AppListTransfer.movedBack(suite, localDestination: destination, externalSourceRemains: sourceRemains,
                                  retiredLocalURLs: [retired]).apply(localApps: &local, externalApps: &external)
        #expect(local.map(\.path) == [destination])
        #expect(local.first?.status == AppStatus.local)
        #expect(external.contains(unrelated))
        #expect(external.count == (sourceRemains ? 2 : 1))
        if sourceRemains { #expect(external.first?.status == AppStatus.unlinked) }
    }
}
