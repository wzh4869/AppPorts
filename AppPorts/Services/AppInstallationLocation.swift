import AppKit

enum AppInstallationLocation {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "请移动 AppPorts，并从“应用程序”文件夹重新打开后，再继续此操作。".localized
        }
    }

    static func isAllowed(_ url: URL = Bundle.main.bundleURL,
                          homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        url.isFileURL && ContainerMountAgentInstaller.isInApplicationsFolder(
            url.resolvingSymlinksInPath(), homeDirectory: homeDirectory.resolvingSymlinksInPath())
    }

    static func require(_ url: URL = Bundle.main.bundleURL,
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard isAllowed(url, homeDirectory: homeDirectory) else { throw Failure() }
    }

    @MainActor
    static func confirmIfNeeded(applicationURL: URL = Bundle.main.bundleURL,
                                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                present: @MainActor () -> Void = presentGuidance) -> Bool {
        guard !isAllowed(applicationURL, homeDirectory: homeDirectory) else { return true }
        present()
        return false
    }

    @MainActor
    private static func presentGuidance() {
        let alert = NSAlert()
        alert.messageText = "请先将 AppPorts 放入“应用程序”文件夹".localized
        alert.informativeText = Failure().localizedDescription
        alert.addButton(withTitle: "打开应用程序文件夹".localized)
        alert.addButton(withTitle: "取消".localized)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
    }
}
