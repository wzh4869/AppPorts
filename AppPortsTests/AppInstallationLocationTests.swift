import Foundation
import Testing
@testable import AppPorts

struct AppInstallationLocationTests {
    @Test(arguments: [
        ("/Applications/AppPorts.app", true),
        ("/Applications/Utilities/AppPorts.app", true),
        ("/fixture/user/Applications/AppPorts.app", true),
        ("/fixture/user/Downloads/AppPorts.app", false),
        ("/fixture/user/Documents/AppPorts.app", false),
        ("/Applications-other/AppPorts.app", false)
    ])
    func requiresAnApplicationsDirectory(path: String, allowed: Bool) {
        let url = URL(fileURLWithPath: path)
        let home = URL(fileURLWithPath: "/fixture/user")
        #expect(AppInstallationLocation.isAllowed(url, homeDirectory: home) == allowed)
    }

    @Test func applicationsSymlinkDoesNotHideADeletedBuildLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("User")
        let directory = home.appendingPathComponent("Applications")
        let build = root.appendingPathComponent("Build/AppPorts.app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("AppPorts.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: build)
        #expect(!AppInstallationLocation.isAllowed(link, homeDirectory: home))
    }

    @Test @MainActor func rejectedOperationShowsGuidanceAndDoesNotContinue() {
        var prompts = 0
        let denied = AppInstallationLocation.confirmIfNeeded(
            applicationURL: URL(fileURLWithPath: "/fixture/Downloads/AppPorts.app"), present: { prompts += 1 })
        #expect(!denied)
        #expect(prompts == 1)
        let allowed = AppInstallationLocation.confirmIfNeeded(
            applicationURL: URL(fileURLWithPath: "/Applications/AppPorts.app"), present: { prompts += 1 })
        #expect(allowed)
        #expect(prompts == 1)
    }
}
