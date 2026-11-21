import AppKit

/// Only created before this outward transfer has a journal or starts copying.
struct AppMigrationStartBlock: LocalizedError, Sendable {
    let source: URL
    let destination: URL
    private let sourceIdentity: DataPathIdentity
    private let destinationParentIdentity: DataPathIdentity
    private let destinationIdentity: DataPathIdentity?
    private let applicationURLs: [URL]
    private let identifiers: Set<String>

    init(source: URL, destination: URL, applicationPaths: [String]) throws {
        self.source = source
        self.destination = destination
        sourceIdentity = try .capture(source)
        destinationParentIdentity = try .capture(destination.deletingLastPathComponent())
        destinationIdentity = try AppTransferStore.exists(destination) ? .capture(destination) : nil
        applicationURLs = applicationPaths.map { $0.isEmpty ? source : source.appendingPathComponent($0) }
        identifiers = Set(applicationURLs.compactMap { CodeSigner.bundleIdentifier(at: $0) })
    }

    var errorDescription: String? { "应用正在运行，迁移尚未开始。应用仍在原位置。".localized }

    func validate() throws {
        let current = try AppTransferStore.exists(destination) ? DataPathIdentity.capture(destination) : nil
        guard try sourceIdentity.matchesFilesystemObject(.capture(source)),
              try destinationParentIdentity.matchesFilesystemObject(.capture(destination.deletingLastPathComponent())),
              destinationIdentity.map({ expected in current.map(expected.matchesFilesystemObject) == true }) ?? (current == nil)
        else {
            throw AppTransferTransaction.failure("确认后源应用或目标应用已改变，请重新选择替换。".localized, at: source)
        }
    }

    @MainActor
    func quitAndWait() async throws -> Bool {
        let applications = runningApplications()
        for application in applications where !application.isTerminated {
            if !application.terminate(), !application.isTerminated { return false }
        }
        // Normal termination can wait for a document to be saved. Leaving the detail cancels the wait.
        while applications.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
        return runningApplications().isEmpty
    }

    @MainActor
    func runningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { application in
            guard !application.isTerminated else { return false }
            if let id = application.bundleIdentifier, identifiers.contains(id) { return true }
            guard let path = application.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path else { return false }
            return path == source.path || path.hasPrefix(source.path + "/")
                || applicationURLs.contains { $0.resolvingSymlinksInPath().path == path }
        }
    }
}
