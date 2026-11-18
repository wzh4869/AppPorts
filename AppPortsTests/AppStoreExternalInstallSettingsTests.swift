import CoreFoundation
import Foundation
import XCTest
@testable import AppPorts

@MainActor
final class AppStoreExternalInstallSettingsTests: XCTestCase {
    func testReadsConfiguredAndClearedPreferenceThroughPreferencesService() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        XCTAssertEqual(AppStoreExternalInstallPreference.read(domain: fixture.suite), .disabled)
        try fixture.writePreference(["volumeID": fixture.volume.uuidString, "name": "Validation", "iconPath": "/fixture/icon"])
        XCTAssertEqual(AppStoreExternalInstallPreference.read(domain: fixture.suite), .enabled(volumeUUID: fixture.volume, name: "Validation"))
        try fixture.writePreference(nil)
        XCTAssertEqual(AppStoreExternalInstallPreference.read(domain: fixture.suite), .disabled)
    }

    func testMalformedPreferenceCannotAppearConfigured() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for value: Any in ["not a dictionary", ["name": "Validation"], ["volumeID": "invalid-uuid"]] {
            try fixture.writePreference(value)
            XCTAssertEqual(AppStoreExternalInstallPreference.read(domain: fixture.suite), .unknown)
        }
        try fixture.writePreference([String: String]())
        XCTAssertEqual(AppStoreExternalInstallPreference.read(domain: fixture.suite), .disabled)
    }

    func testConfiguredDriveIsReadyWithoutAnApplicationsFolder() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let settings = fixture.settings(preference: .enabled(volumeUUID: fixture.volume, name: "Validation"))
        settings.refresh(for: fixture.root)
        XCTAssertEqual(settings.state, .ready)
        XCTAssertFalse(settings.shouldPresentGuidance)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(settings.destinationURL).path))
    }

    func testApplicationsFolderDoesNotReplaceActualAppStoreSetting() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        let settings = fixture.settings(preference: .disabled)
        settings.refresh(for: fixture.root)
        XCTAssertEqual(settings.state, .notConfigured)
        XCTAssertTrue(settings.shouldPresentGuidance)
    }

    func testRecheckingCompletedConfigurationStopsReminder() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writePreference(nil)
        let settings = AppStoreExternalInstallSettings(defaults: fixture.defaults,
            probe: .init(preference: { AppStoreExternalInstallPreference.read(domain: fixture.suite) }, volumeUUID: { _ in fixture.volume }), isSupported: true)
        settings.refresh(for: fixture.root)
        XCTAssertTrue(settings.shouldPresentGuidance)
        try fixture.writePreference(["volumeID": fixture.volume.uuidString, "name": "Validation"])
        settings.refresh(for: fixture.root)
        XCTAssertEqual(settings.state, .ready)
        XCTAssertFalse(settings.shouldPresentGuidance)
        XCTAssertFalse(fixture.defaults.bool(forKey: AppStoreExternalInstallSettings.dismissGuidanceKey))
    }

    func testDontRemindPersistsWithoutFakingConfigurationOrRemovingSettingsAction() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let settings = fixture.settings(preference: .disabled)
        settings.refresh(for: fixture.root)
        var opened = false
        let request = settings.makeGuidanceRequest(onOpenAppStore: { opened = true }, onCheck: {})
        XCTAssertEqual(request.cancelTitle, "Don’t remind me again".localized)
        XCTAssertEqual(request.bullets.first?.icon, "gearshape")
        XCTAssertEqual(request.actions.count, 2)
        request.onCancel()
        let reopened = fixture.settings(preference: .disabled)
        reopened.refresh(for: fixture.root)
        XCTAssertEqual(reopened.state, .notConfigured)
        XCTAssertFalse(reopened.shouldPresentGuidance)
        request.actions[0].handler()
        XCTAssertTrue(opened)
    }

    func testIHaveConfiguredButtonRechecksWithoutCreatingFolderOrSilencingReminder() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let settings = fixture.settings(preference: .disabled)
        settings.refresh(for: fixture.root)
        var checks = 0
        let request = settings.makeGuidanceRequest(onOpenAppStore: {}, onCheck: {
            checks += 1
            settings.refresh(for: fixture.root)
        })
        request.actions[1].handler()
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(settings.state, .notConfigured)
        XCTAssertTrue(settings.shouldPresentGuidance)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(settings.destinationURL).path))
    }

    func testMatchingUsesVolumeIdentityAndExistingMigrationDestination() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var inspected: URL?
        let settings = AppStoreExternalInstallSettings(defaults: fixture.defaults,
            probe: .init(preference: { .enabled(volumeUUID: fixture.volume, name: "Validation") }, volumeUUID: { url in
                inspected = url
                return fixture.volume
            }), isSupported: true)
        settings.refresh(for: URL(fileURLWithPath: "/Volumes/Validation/appdisks/AppPorts.noindex"))
        XCTAssertEqual(settings.state, .ready)
        XCTAssertEqual(inspected?.path, "/Volumes/Validation")
        XCTAssertEqual(settings.destinationURL?.path, "/Volumes/Validation/Applications")
    }

    func testDifferentVolumeNeedsSetupWhileUnknownOrOfflineDoesNotBecomeReady() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let other = fixture.settings(preference: .enabled(volumeUUID: UUID(), name: "Other drive"))
        other.refresh(for: fixture.root)
        XCTAssertEqual(other.state, .differentVolume(name: "Other drive"))
        XCTAssertTrue(other.shouldPresentGuidance)
        let unknown = fixture.settings(preference: .unknown)
        unknown.refresh(for: fixture.root)
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertFalse(unknown.shouldPresentGuidance)
        let offline = AppStoreExternalInstallSettings(defaults: fixture.defaults,
            probe: .init(preference: { .enabled(volumeUUID: fixture.volume, name: "Validation") }, volumeUUID: { _ in nil }), isSupported: true)
        offline.refresh(for: fixture.root)
        XCTAssertEqual(offline.state, .unavailable)
        XCTAssertFalse(offline.shouldPresentGuidance)
    }

    func testUnsupportedOrUnselectedStorageDoesNotProbeOrPrompt() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var calls = 0
        let probe = AppStoreExternalInstallSettings.Probe(preference: { calls += 1; return .disabled }, volumeUUID: { _ in nil })
        let unsupported = AppStoreExternalInstallSettings(defaults: fixture.defaults, probe: probe, isSupported: false)
        unsupported.refresh(for: fixture.root)
        XCTAssertEqual(unsupported.state, .unsupported)
        XCTAssertFalse(unsupported.shouldPresentGuidance)
        let unselected = AppStoreExternalInstallSettings(defaults: fixture.defaults, probe: probe, isSupported: true)
        unselected.refresh(for: nil)
        XCTAssertEqual(unselected.state, .notSelected)
        XCTAssertFalse(unselected.shouldPresentGuidance)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    private final class Fixture {
        let suite = "AppStoreExternalInstallTests-" + UUID().uuidString
        let root: URL
        let defaults: UserDefaults
        let volume = UUID()

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func writePreference(_ value: Any?) throws {
            CFPreferencesSetValue("PreferredVolume" as CFString, value as CFPropertyList?, suite as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            XCTAssertTrue(CFPreferencesSynchronize(suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        }

        func settings(preference: AppStoreExternalInstallPreference) -> AppStoreExternalInstallSettings {
            AppStoreExternalInstallSettings(defaults: defaults,
                probe: .init(preference: { preference }, volumeUUID: { _ in self.volume }), isSupported: true)
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
