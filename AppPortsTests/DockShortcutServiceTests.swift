import Foundation
import Testing
@testable import AppPorts

@Suite("Existing Dock shortcut repair")
struct DockShortcutServiceTests {
    @Test("Inspection reports old-path pins without mutating even managed preferences", arguments: [false, true])
    func inspectsOldPathWithoutEffects(managed: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        let original = [tile(url: source), tile(url: source, identifier: "com.appports.tests.target", guid: 2)]
        let store = MemoryStore(original)
        store.managed = managed
        let effects = Effects()

        #expect(try makeInspectionService(store, effects).needsRedirect(from: source, to: target))
        #expect((try #require(store.tiles) as NSArray).isEqual(original as NSArray))
        #expect(store.writes == 0)
        #expect(effects.bookmarkCreations == 0)
        #expect(effects.reloads == 0)
    }

    enum ExistingPinState: CaseIterable { case complete, missingBookmark, invalidBookmark, unrelatedBookmark, stubIdentifier, legacyURL }

    @Test("Inspection reports only destination pins that the same repair call can update", arguments: ExistingPinState.allCases)
    func inspectsDestinationPin(state: ExistingPinState) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        var entry = state == .legacyURL ? legacyTile(url: target) : tile(url: target)
        var data = entry["tile-data"] as! [String: Any]
        data["bundle-identifier"] = "com.appports.tests.target"
        data["book"] = try DockShortcutService.Bookmarks.fileSystem.create(target)
        switch state {
        case .complete, .legacyURL: break
        case .missingBookmark: data.removeValue(forKey: "book")
        case .invalidBookmark: data["book"] = Data("invalid bookmark".utf8)
        case .unrelatedBookmark:
            let other = try fixture.makeApp("Other/Pages.app")
            data["book"] = try DockShortcutService.Bookmarks.fileSystem.create(other)
        case .stubIdentifier: data["bundle-identifier"] = "com.appports.tests.target.appports.stub"
        }
        entry["tile-data"] = data
        let store = MemoryStore([entry])
        let effects = Effects()
        let service = makeInspectionService(store, effects)

        #expect(try service.needsRedirect(from: source, to: target) == (state == .stubIdentifier))
        // The caller uses this form when the former source path is occupied by another app.
        #expect(try service.needsRedirect(from: target, to: target) == (state != .complete))
        #expect(equal(try #require(store.tiles?.first), entry))
        #expect(store.writes == 0)
        #expect(effects.bookmarkCreations == 0)
        #expect(effects.reloads == 0)

        let repairStore = MemoryStore([entry])
        #expect(try makeService(repairStore, Effects()).redirectShortcuts(
            from: source, to: target, requiringBundleIdentity: true
        ) == (state == .stubIdentifier ? 1 : 0))
        #expect(try !makeInspectionService(repairStore, Effects()).needsRedirect(from: source, to: target))
    }

    @Test("Inspection never considers unrelated same-name pins or nested helper apps", arguments: [false, true])
    func inspectionIgnoresUnrelatedPins(absentList: Bool) throws {
        let source = URL(fileURLWithPath: "/Applications/Pages.app")
        let store = MemoryStore(absentList ? nil : [
            tile(url: URL(fileURLWithPath: "/Elsewhere/Pages.app")),
            tile(url: source.appendingPathComponent("Contents/Helper.app"), guid: 2)
        ])
        let effects = Effects()
        let service = makeInspectionService(store, effects, identifier: { _ in
            effects.inspections += 1
            throw DockShortcutService.ShortcutError.destinationUnavailable
        })

        #expect(try !service.needsRedirect(from: source, to: URL(fileURLWithPath: "/Missing/Pages.app")))
        #expect(effects.inspections == 0)
        #expect(store.writes == 0)
        #expect(effects.bookmarkCreations == 0)
        #expect(effects.reloads == 0)
    }

    @Test("Inspection requires matching bundle identities by default, including after a pending pin", arguments: [false, true])
    func inspectionValidatesEveryIdentity(missingIdentity: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        var conflicting = tile(
            url: missingIdentity ? source : target,
            identifier: "com.other.pages.appports.stub", guid: 2
        )
        if missingIdentity {
            var data = conflicting["tile-data"] as! [String: Any]
            data.removeValue(forKey: "bundle-identifier")
            conflicting["tile-data"] = data
        }
        let original = [tile(url: source), conflicting]
        let store = MemoryStore(original)
        let effects = Effects()
        let service = makeInspectionService(store, effects)

        #expect(throws: DockShortcutService.ShortcutError.invalidBundleIdentifier) {
            try service.needsRedirect(from: source, to: target)
        }
        #expect(try service.needsRedirect(from: source, to: target, requiringBundleIdentity: false))
        #expect((try #require(store.tiles) as NSArray).isEqual(original as NSArray))
        #expect(store.writes == 0)
        #expect(effects.bookmarkCreations == 0)
        #expect(effects.reloads == 0)
    }

    @Test("Inspection propagates unavailable preferences without side effects", arguments: [false, true])
    func inspectionPropagatesPreferenceErrors(malformed: Bool) throws {
        let source = URL(fileURLWithPath: "/Applications/Pages.app")
        let store = MemoryStore([tile(url: source)])
        store.readFailure = !malformed
        if malformed { store.preferences["persistent-apps"] = ["invalid": true] }
        let effects = Effects()
        let service = makeInspectionService(store, effects)

        #expect(throws: malformed ? DockShortcutService.ShortcutError.malformedPreferences : .preferencesReadFailed) {
            try service.needsRedirect(from: source, to: URL(fileURLWithPath: "/Missing/Pages.app"))
        }
        #expect(store.writes == 0)
        #expect(effects.bookmarkCreations == 0)
        #expect(effects.reloads == 0)
    }

    @Test("Pages switches from its local stub to the real application without changing tile identity")
    func pagesPreservesTileIdentityAndUnrelatedFields() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Applications/Pages.app")
        let target = try fixture.makeApp("External/Pages.app", identifier: "com.apple.iWork.Pages")
        let other = tile(url: fixture.url("Other/Pages.app"), identifier: "com.apple.iWork.Pages", guid: 2)
        let spacer: [String: Any] = ["GUID": 3, "tile-type": "spacer-tile", "future-key": ["flag": true]]
        var pages = tile(url: source, identifier: "com.apple.iWork.Pages.appports.stub", guid: 1)
        var data = pages["tile-data"] as! [String: Any]
        // A bookmark can already follow the real moved app while file-data still has the old URL.
        data["book"] = try DockShortcutService.Bookmarks.fileSystem.create(target)
        pages["tile-data"] = data
        let store = MemoryStore([pages, spacer, other])
        let effects = Effects()
        let service = makeService(store, effects)

        #expect(try service.redirectShortcuts(from: source, to: target) == 1)
        let saved = try #require(store.tiles)
        #expect(saved.count == 3)
        #expect(saved.compactMap { $0["GUID"] as? Int } == [1, 3, 2])
        #expect(equal(saved[1], spacer))
        #expect(equal(saved[2], other))
        let updated = try #require(saved[0]["tile-data"] as? [String: Any])
        let file = try #require(updated["file-data"] as? [String: Any])
        #expect(file["_CFURLString"] as? String == target.absoluteString)
        #expect(file["_CFURLStringType"] as? Int == 15)
        #expect(file["future-url-key"] as? String == "keep")
        #expect(updated["bundle-identifier"] as? String == "com.apple.iWork.Pages")
        #expect(updated["file-label"] as? String == "Existing label")
        #expect(updated["future-tile-key"] as? [Int] == [7, 8])
        #expect(updated["file-mod-date"] == nil)
        #expect(updated["parent-mod-date"] == nil)
        #expect(saved[0]["future-root-key"] as? String == "keep")
        let bookmark = try #require(updated["book"] as? Data)
        let resolved = try DockShortcutService.Bookmarks.fileSystem.resolve(bookmark)
        #expect(resolved.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path)
        #expect(store.preferences["unrelated-preference"] as? String == "untouched")
        #expect(store.writes == 1)
        #expect(effects.reloads == 1)
    }

    @Test("File URLs retain spaces, Chinese characters, and reserved characters", arguments: [
        "Pages.app", "中文 文件.app", "A #?%'s.app"
    ])
    func encodedFileURLs(name: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/" + name)
        let target = try fixture.makeApp("External/" + name)
        let store = MemoryStore([tile(url: source)])
        let effects = Effects()

        #expect(try makeService(store, effects).redirectShortcuts(from: source, to: target) == 1)
        #expect(try savedURL(store).path == target.path)
    }

    @Test("Legacy absolute-path tiles are repaired or preserved according to their exact paths", arguments: [false, true])
    func legacyPathTiles(matchingTileIsLegacy: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/中文 #?% Pages.app")
        let target = try fixture.makeApp("External/中文 #?% Pages.app")
        let unrelated = legacyTile(url: fixture.url("Other/中文 #?% Pages.app"), guid: 2)
        let matched = matchingTileIsLegacy ? legacyTile(url: source) : tile(url: source)
        let store = MemoryStore([unrelated, matched])
        let effects = Effects()

        #expect(try makeService(store, effects).redirectShortcuts(from: source, to: target) == 1)
        let saved = try #require(store.tiles)
        #expect(equal(saved[0], unrelated))
        #expect(saved.compactMap { $0["GUID"] as? Int } == [2, 1])
        #expect(try savedURL(store, index: 1).path == target.path)
        let data = try #require(saved[1]["tile-data"] as? [String: Any])
        let file = try #require(data["file-data"] as? [String: Any])
        #expect(file["_CFURLStringType"] as? Int == 15)
        #expect(file["future-url-key"] as? String == "keep")
        #expect(effects.reloads == 1)
    }

    @Test("An unrelated valid legacy path tile does not inspect an unavailable destination")
    func unrelatedLegacyTileHasNoSideEffects() throws {
        let unrelated = legacyTile(url: URL(fileURLWithPath: "/Elsewhere/Pages.app"))
        let store = MemoryStore([unrelated])
        let effects = Effects()
        let service = makeService(store, effects, identifier: { _ in
            effects.inspections += 1
            throw DockShortcutService.ShortcutError.destinationUnavailable
        })
        #expect(try service.redirectShortcuts(
            from: URL(fileURLWithPath: "/Applications/Pages.app"),
            to: URL(fileURLWithPath: "/Volumes/Missing/Pages.app")
        ) == 0)
        #expect(equal(try #require(store.tiles?.first), unrelated))
        #expect(effects.inspections == 0)
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    @Test("A source symlink retains its local identity during matching")
    func sourceSymlinkIsNotResolvedForMatching() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = try fixture.makeApp("External/Pages.app")
        let source = fixture.url("Pages.app")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        let store = MemoryStore([tile(url: source)])

        #expect(try makeService(store, Effects()).redirectShortcuts(from: source, to: target) == 1)
        #expect(try savedURL(store).path == target.path)
    }

    @Test("Parent traversal across a symlink cannot redirect a different application's pin")
    func rejectsAmbiguousParentTraversal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = try fixture.makeApp("Destination/Pages.app")
        try FileManager.default.createDirectory(at: fixture.url("Local"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.url("Elsewhere/Nested"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.url("Local/link"), withDestinationURL: fixture.url("Elsewhere/Nested"))
        let ambiguous = try #require(URL(string: fixture.url("Local").absoluteString + "/link/../Pages.app"))
        let store = MemoryStore([tile(url: fixture.url("Local/Pages.app"))])
        let effects = Effects()

        #expect(throws: DockShortcutService.ShortcutError.self) {
            try makeService(store, effects).redirectShortcuts(from: ambiguous, to: target)
        }
        #expect(store.reads == 0)
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    @Test("A real bookmark can follow a moved app while its stored Dock URL still points to the source")
    func movedBookmarkDoesNotHideTheOldDockURL() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.makeApp("Local/Pages.app")
        let target = fixture.url("External/Pages.app")
        let originalBookmark = try DockShortcutService.Bookmarks.fileSystem.create(source)
        var entry = tile(url: source)
        var data = entry["tile-data"] as! [String: Any]
        data["book"] = originalBookmark
        entry["tile-data"] = data
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
        let followed = try DockShortcutService.Bookmarks.fileSystem.resolve(originalBookmark)
        #expect(followed.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path)
        let store = MemoryStore([entry])
        #expect(try makeService(store, Effects()).redirectShortcuts(from: source, to: target) == 1)
        #expect(try savedURL(store).path == target.path)
    }

    @Test("Canonical bookmark paths do not trigger a redundant rewrite of the same destination")
    func canonicalBookmarkPathIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = try fixture.makeApp("Pages.app")
        var entry = tile(url: target, identifier: "com.appports.tests.target")
        var data = entry["tile-data"] as! [String: Any]
        data["book"] = try DockShortcutService.Bookmarks.fileSystem.create(target)
        entry["tile-data"] = data
        let store = MemoryStore([entry])
        let effects = Effects()
        #expect(try makeService(store, effects).redirectShortcuts(from: target, to: target) == 0)
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    @Test("A directory suite maps application descendants but not similar path prefixes")
    func directoryDescendantsRespectPathComponents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Suite")
        let destination = fixture.url("External/Suite")
        let pages = try fixture.makeApp("External/Suite/Pages.app", identifier: "com.apple.iWork.Pages")
        let numbers = try fixture.makeApp("External/Suite/Nested/Numbers.app", identifier: "com.apple.iWork.Numbers")
        let unrelated = tile(url: fixture.url("Local/SuiteExtra/Pages.app"), guid: 3)
        let store = MemoryStore([
            tile(url: source.appendingPathComponent("Pages.app"), guid: 1),
            tile(url: source.appendingPathComponent("Nested/Numbers.app"), guid: 2),
            unrelated
        ])

        #expect(try makeService(store, Effects()).redirectShortcuts(from: source, to: destination) == 2)
        #expect(try savedURL(store, index: 0).path == pages.path)
        #expect(try savedURL(store, index: 1).path == numbers.path)
        #expect(equal(try #require(store.tiles?[2]), unrelated))
    }

    @Test("An application root does not redirect its nested helper applications")
    func applicationRootIsNotASuiteDirectory() throws {
        let store = MemoryStore([tile(url: URL(fileURLWithPath: "/Applications/Pages.app/Contents/Helper.app"))])
        let effects = Effects()
        let service = makeService(store, effects, identifier: { _ in
            effects.inspections += 1
            throw DockShortcutService.ShortcutError.destinationUnavailable
        })
        #expect(try service.redirectShortcuts(
            from: URL(fileURLWithPath: "/Applications/Pages.app"),
            to: URL(fileURLWithPath: "/Volumes/Missing/Pages.app")
        ) == 0)
        #expect(effects.inspections == 0)
        #expect(store.writes == 0)
    }

    @Test("Migration and restoration work when the source has already disappeared", arguments: [false, true])
    func missingSourceIsAllowed(restoring: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url(restoring ? "External/Pages.app" : "Local/Pages.app")
        let target = try fixture.makeApp(restoring ? "Local/Pages.app" : "External/Pages.app")
        let store = MemoryStore([tile(url: source)])
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try makeService(store, Effects()).redirectShortcuts(from: source, to: target) == 1)
        #expect(try savedURL(store).path == target.path)
    }

    @Test("Already redirected entries with a cached stub ID are repaired; repeated repair is a no-op")
    func destinationStubIdentityAndIdempotency() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        let store = MemoryStore([tile(url: target)])
        let effects = Effects()
        let service = makeService(store, effects)

        #expect(try service.redirectShortcuts(from: source, to: target) == 1)
        #expect(try service.redirectShortcuts(from: source, to: target) == 0)
        #expect(store.writes == 1)
        #expect(effects.reloads == 1)
    }

    @Test("An unpinned app never triggers target IO, a write, or a Dock reload", arguments: [false, true])
    func noMatchingTileHasNoSideEffects(absentList: Bool) throws {
        let source = URL(fileURLWithPath: "/Applications/Pages.app")
        let store = MemoryStore(absentList ? nil : [tile(url: URL(fileURLWithPath: "/Elsewhere/Pages.app"))])
        let effects = Effects()
        let service = makeService(store, effects, identifier: { _ in
            effects.inspections += 1
            throw DockShortcutService.ShortcutError.destinationUnavailable
        })
        #expect(try service.redirectShortcuts(from: source, to: URL(fileURLWithPath: "/Volumes/Missing/Pages.app")) == 0)
        #expect(effects.inspections == 0)
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    enum InvalidDestination: CaseIterable { case missing, regularFile, noIdentifier, stubIdentifier, malformedPlist }

    @Test("Unavailable or invalid destinations never alter Dock preferences", arguments: InvalidDestination.allCases)
    func rejectsInvalidDestination(kind: InvalidDestination) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = fixture.url("Pages.app")
        switch kind {
        case .missing: break
        case .regularFile: try Data().write(to: target)
        case .noIdentifier:
            try fixture.writePlist(["CFBundleName": "Pages"], relativePath: "Pages.app/Contents/Info.plist")
        case .stubIdentifier:
            _ = try fixture.makeApp("Pages.app", identifier: "com.apple.iWork.Pages.appports.stub")
        case .malformedPlist:
            try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data("invalid plist".utf8).write(to: target.appendingPathComponent("Contents/Info.plist"))
        }
        let store = MemoryStore([tile(url: source)])
        let effects = Effects()
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try makeService(store, effects).redirectShortcuts(from: source, to: target)
        }
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    @Test("A missing member of a pinned suite aborts the entire update")
    func suiteChangesArePreparedBeforeWriting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.makeApp("External/Suite/Pages.app")
        let source = fixture.url("Local/Suite")
        let original = [tile(url: source.appendingPathComponent("Pages.app"), guid: 1), tile(url: source.appendingPathComponent("Missing.app"), guid: 2)]
        let store = MemoryStore(original)
        let effects = Effects()
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try makeService(store, effects).redirectShortcuts(from: source, to: fixture.url("External/Suite"))
        }
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
        #expect((try #require(store.tiles) as NSArray).isEqual(original as NSArray))
    }

    @Test("Absolute remote URLs and relative URLs are rejected", arguments: [
        "https://example.invalid/Pages.app", "file://server/Pages.app", "Pages.app", "file:Pages.app",
        "file:///Applications/Pages.app?query", "file:///Applications/Pages.app#fragment", "file:///Applications/%00Pages.app",
        "file:///Applications/link/../Pages.app", "file:///Applications/link/%2E%2E/Pages.app"
    ])
    func rejectsNonlocalOrRelativeURL(value: String) throws {
        let invalid = try #require(URL(string: value))
        let store = MemoryStore([])
        let service = makeService(store, Effects())
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try service.redirectShortcuts(from: invalid, to: URL(fileURLWithPath: "/Applications/Target.app"))
        }
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try service.redirectShortcuts(from: URL(fileURLWithPath: "/Applications/Source.app"), to: invalid)
        }
        #expect(store.reads == 0)
    }

    enum MalformedData: CaseIterable {
        case notArray, notDictionary, noType, noFileData, remoteURL, relativeURL, invalidURLType
        case unsupportedURLType, booleanURLType, relativeLegacyPath, parentTraversalURL, parentTraversalLegacyPath
        case invalidBook, invalidIdentifier
    }

    @Test("Malformed persistent-apps is rejected without writing", arguments: MalformedData.allCases)
    func malformedPreferences(kind: MalformedData) throws {
        let source = URL(fileURLWithPath: "/Applications/Pages.app")
        var entry = tile(url: source)
        var data = entry["tile-data"] as! [String: Any]
        var file = data["file-data"] as! [String: Any]
        switch kind {
        case .noType: entry.removeValue(forKey: "tile-type")
        case .noFileData: data.removeValue(forKey: "file-data")
        case .remoteURL: file["_CFURLString"] = "file://server/Pages.app"
        case .relativeURL: file["_CFURLString"] = "Pages.app"
        case .invalidURLType: file["_CFURLStringType"] = "15"
        case .unsupportedURLType: file["_CFURLStringType"] = 9
        case .booleanURLType: file["_CFURLStringType"] = false
        case .relativeLegacyPath:
            file["_CFURLString"] = "Pages.app"
            file["_CFURLStringType"] = 0
        case .parentTraversalURL: file["_CFURLString"] = "file:///Applications/link/../Pages.app"
        case .parentTraversalLegacyPath:
            file["_CFURLString"] = "/Applications/link/../Pages.app"
            file["_CFURLStringType"] = 0
        case .invalidBook: data["book"] = "invalid"
        case .invalidIdentifier: data["bundle-identifier"] = 42
        case .notArray, .notDictionary: break
        }
        if kind != .noFileData { data["file-data"] = file }
        entry["tile-data"] = data
        let store = MemoryStore([entry])
        if kind == .notArray { store.preferences["persistent-apps"] = ["invalid": true] }
        if kind == .notDictionary { store.preferences["persistent-apps"] = [42] }
        let effects = Effects()
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try makeService(store, effects).redirectShortcuts(from: source, to: URL(fileURLWithPath: "/Missing/Pages.app"))
        }
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    @Test("Managed preferences are refused before inspecting the destination")
    func managedPreferences() throws {
        let source = URL(fileURLWithPath: "/Applications/Pages.app")
        let store = MemoryStore([tile(url: source)])
        store.managed = true
        let effects = Effects()
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try makeService(store, effects, identifier: { _ in
                effects.inspections += 1
                return "com.apple.iWork.Pages"
            }).redirectShortcuts(from: source, to: URL(fileURLWithPath: "/Missing/Pages.app"))
        }
        #expect(effects.inspections == 0)
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    enum StoreFailure: CaseIterable { case read, write, verification }

    @Test("A read, write, or verification failure never reloads Dock", arguments: StoreFailure.allCases)
    func storeFailures(kind: StoreFailure) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        let store = MemoryStore([tile(url: source)])
        store.readFailure = kind == .read
        store.writeFailure = kind == .write
        store.ignoreWrite = kind == .verification
        let effects = Effects()
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try makeService(store, effects).redirectShortcuts(from: source, to: target)
        }
        #expect(effects.reloads == 0)
        #expect(try savedURL(store).path == source.path)
    }

    enum InvalidBookmark: CaseIterable { case unrelated, remote, relative, creationFailure }

    @Test("An invalid new bookmark aborts the write", arguments: InvalidBookmark.allCases)
    func bookmarkMustResolveToTheDestination(kind: InvalidBookmark) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        let store = MemoryStore([tile(url: source)])
        let effects = Effects()
        let codec = DockShortcutService.Bookmarks(create: { _ in
            if kind == .creationFailure { throw DockShortcutService.ShortcutError.bookmarkMismatch }
            return Data([1])
        }, resolve: { _ in
            switch kind {
            case .remote:
                var parts = URLComponents(url: target, resolvingAgainstBaseURL: false)!
                parts.host = "remote-server"
                return parts.url!
            case .relative: return URL(string: "Pages.app")!
            case .unrelated, .creationFailure: return source
            }
        })
        let service = DockShortcutService(store: store.adapter, bookmarks: codec, reload: { effects.reloads += 1 })
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try service.redirectShortcuts(from: source, to: target)
        }
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    @Test("Fresh reads preserve concurrent reordering, new pins, unknown fields, and other preferences")
    func rebasesOntoConcurrentChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        let other = tile(url: fixture.url("Other/Pages.app"), guid: 20)
        let added = tile(url: fixture.url("Added.app"), guid: 30)
        let store = MemoryStore([tile(url: source, guid: 10), other])
        store.onRead = { store, count in
            guard count == 2, let original = store.tiles else { return }
            var changed = original[0]
            changed["new-user-field"] = "preserve"
            store.preferences["persistent-apps"] = [other, changed, added]
            store.preferences["unrelated-preference"] = "concurrently changed"
        }
        let effects = Effects()

        #expect(try makeService(store, effects).redirectShortcuts(from: source, to: target) == 1)
        let saved = try #require(store.tiles)
        #expect(saved.compactMap { $0["GUID"] as? Int } == [20, 10, 30])
        #expect(saved[1]["new-user-field"] as? String == "preserve")
        #expect(equal(saved[0], other))
        #expect(equal(saved[2], added))
        #expect(try savedURL(store, index: 1).path == target.path)
        #expect(store.preferences["unrelated-preference"] as? String == "concurrently changed")
        #expect(store.writes == 1)
        #expect(effects.reloads == 1)
    }

    @Test("A tile concurrently unpinned by the user is not recreated")
    func concurrentRemovalDoesNotRecreatePin() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        let store = MemoryStore([tile(url: source)])
        store.onRead = { store, count in
            if count == 2 { store.preferences["persistent-apps"] = [[String: Any]]() }
        }
        let effects = Effects()
        #expect(try makeService(store, effects).redirectShortcuts(from: source, to: target) == 0)
        #expect(store.tiles?.isEmpty == true)
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    @Test("Continually changing preferences exhaust a bounded retry without writing")
    func boundsConcurrentRetries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Pages.app")
        let target = try fixture.makeApp("External/Pages.app")
        let store = MemoryStore([tile(url: source)])
        store.onRead = { store, count in
            guard count > 1, var tiles = store.tiles else { return }
            tiles[0]["concurrent-change"] = count
            store.preferences["persistent-apps"] = tiles
        }
        let effects = Effects()
        #expect(throws: DockShortcutService.ShortcutError.self) {
            try makeService(store, effects).redirectShortcuts(from: source, to: target)
        }
        #expect(store.reads == 4)
        #expect(store.writes == 0)
        #expect(effects.reloads == 0)
    }

    enum IOSLayout: CaseIterable { case rootInfo, wrappedBundle, wrapperDirectory, metadata, wrapperMetadata, wrappedMetadata }

    @Test("iOS wrapper identities keep the outer application as the launch target", arguments: IOSLayout.allCases)
    func iosOuterApplication(layout: IOSLayout) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.url("Local/Mobile.app")
        let target = fixture.url("External/Mobile.app")
        let identifier = "com.appports.tests.mobile"
        switch layout {
        case .rootInfo:
            try fixture.writePlist(["CFBundleIdentifier": identifier], relativePath: "External/Mobile.app/Info.plist")
        case .wrappedBundle:
            try fixture.writePlist(["CFBundleIdentifier": identifier], relativePath: "External/Mobile.app/Wrapper/Inner.app/Info.plist")
            try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Inner.app")
        case .wrapperDirectory:
            try fixture.writePlist(["CFBundleIdentifier": identifier], relativePath: "External/Mobile.app/Wrapper/Inner.app/Info.plist")
        case .metadata:
            try fixture.writePlist(["softwareVersionBundleId": identifier], relativePath: "External/Mobile.app/iTunesMetadata.plist")
        case .wrapperMetadata:
            try fixture.writePlist(["softwareVersionBundleId": identifier], relativePath: "External/Mobile.app/Wrapper/iTunesMetadata.plist")
        case .wrappedMetadata:
            try fixture.writePlist(["softwareVersionBundleId": identifier], relativePath: "External/Mobile.app/Wrapper/Inner.app/iTunesMetadata.plist")
            try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Inner.app")
        }
        let store = MemoryStore([tile(url: source, identifier: identifier + ".appports.stub")])
        #expect(try makeService(store, Effects()).redirectShortcuts(from: source, to: target) == 1)
        #expect(try savedURL(store).path == target.path)
        let data = try #require(store.tiles?.first?["tile-data"] as? [String: Any])
        #expect(data["bundle-identifier"] as? String == identifier)
        let resolved = try DockShortcutService.Bookmarks.fileSystem.resolve(try #require(data["book"] as? Data))
        #expect(resolved.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path)
    }

    @Test("Reload scheduling coalesces a burst without running a real Dock command")
    func coalescesReloadRequests() async throws {
        var continuation: AsyncStream<Void>.Continuation?
        let stream = AsyncStream<Void> { continuation = $0 }
        let sink = try #require(continuation)
        // Swift Testing's timeLimit trait requires macOS 13; keep the macOS 12
        // deployment target while still ending this test if the callback never fires.
        let timeout = Task {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                sink.finish()
            } catch {}
        }
        defer {
            timeout.cancel()
            sink.finish()
        }
        await confirmation("One deferred reload", expectedCount: 1) { confirmed in
            let scheduler = DockShortcutService.ReloadScheduler(delay: 0.02) {
                confirmed()
                sink.yield()
            }
            for _ in 0..<20 { scheduler.schedule() }
            var iterator = stream.makeAsyncIterator()
            let event: Void? = await iterator.next()
            #expect(event != nil)
            // Debouncing itself is time-based; allow any incorrectly uncancelled work to run.
            try? await Task.sleep(nanoseconds: 80_000_000)
            withExtendedLifetime(scheduler) {}
        }
    }

    private func tile(url: URL, identifier: String = "com.appports.tests.target.appports.stub", guid: Int = 1) -> [String: Any] {
        [
            "GUID": guid, "tile-type": "file-tile", "future-root-key": "keep",
            "tile-data": [
                "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15, "future-url-key": "keep"],
                "bundle-identifier": identifier, "file-label": "Existing label",
                "file-mod-date": 1234, "parent-mod-date": 5678, "future-tile-key": [7, 8]
            ] as [String: Any]
        ]
    }

    private func legacyTile(url: URL, guid: Int = 1) -> [String: Any] {
        var entry = tile(url: url, guid: guid)
        var data = entry["tile-data"] as! [String: Any]
        var file = data["file-data"] as! [String: Any]
        file["_CFURLString"] = url.path
        file["_CFURLStringType"] = 0
        data["file-data"] = file
        entry["tile-data"] = data
        return entry
    }

    private func makeService(
        _ store: MemoryStore, _ effects: Effects,
        identifier: ((URL) throws -> String)? = nil
    ) -> DockShortcutService {
        DockShortcutService(store: store.adapter, applicationIdentifier: identifier, reload: { effects.reloads += 1 })
    }

    private func makeInspectionService(
        _ store: MemoryStore, _ effects: Effects,
        identifier: ((URL) throws -> String)? = nil
    ) -> DockShortcutService {
        let bookmarks = DockShortcutService.Bookmarks(create: { _ in
            effects.bookmarkCreations += 1
            throw DockShortcutService.ShortcutError.bookmarkMismatch
        }, resolve: DockShortcutService.Bookmarks.fileSystem.resolve)
        return DockShortcutService(
            store: store.adapter, bookmarks: bookmarks, applicationIdentifier: identifier,
            reload: { effects.reloads += 1 }
        )
    }

    private func savedURL(_ store: MemoryStore, index: Int = 0) throws -> URL {
        let data = try #require(store.tiles?[index]["tile-data"] as? [String: Any])
        let file = try #require(data["file-data"] as? [String: Any])
        let string = try #require(file["_CFURLString"] as? String)
        return try #require(URL(string: string))
    }

    private func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        (lhs as NSDictionary).isEqual(rhs as NSDictionary)
    }

    private final class Effects {
        var inspections = 0
        var bookmarkCreations = 0
        var reloads = 0
    }

    private final class MemoryStore {
        var preferences: [String: Any] = ["unrelated-preference": "untouched"]
        var reads = 0
        var writes = 0
        var managed = false
        var readFailure = false
        var writeFailure = false
        var ignoreWrite = false
        var onRead: ((MemoryStore, Int) -> Void)?
        var tiles: [[String: Any]]? { preferences["persistent-apps"] as? [[String: Any]] }

        init(_ tiles: [[String: Any]]?) { preferences["persistent-apps"] = tiles }

        var adapter: DockShortcutService.Store {
            .init(read: { [self] in
                reads += 1
                if readFailure { throw DockShortcutService.ShortcutError.preferencesReadFailed }
                onRead?(self, reads)
                return preferences["persistent-apps"]
            }, write: { [self] updated in
                writes += 1
                if writeFailure { throw DockShortcutService.ShortcutError.preferencesWriteFailed }
                if !ignoreWrite { preferences["persistent-apps"] = updated }
            }, isManaged: { [self] in managed })
        }
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsDockTests-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func url(_ path: String) -> URL { root.appendingPathComponent(path) }

        func makeApp(_ path: String, identifier: String = "com.appports.tests.target") throws -> URL {
            try writePlist(["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"], relativePath: path + "/Contents/Info.plist")
            return url(path)
        }

        func writePlist(_ dictionary: [String: Any], relativePath: String) throws {
            let destination = url(relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: destination)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
