import Foundation

/// A one-shot, windowless preparation request from a managed native portal.
/// Physical disks are never attached or mounted by this entry point.
enum PortalImageLaunchPreparation {
    static let argument = "--prepare-image-launch"
    static let helperKey = "AppPortsLaunchHelperPath"
    static let imageKey = "AppPortsLaunchImageRecord"

    struct Request: Sendable {
        let identifier: String
        let targetPath: String
        let image: AppLibraryImageService.Record?
    }

    struct Plan: Sendable {
        let image: AppLibraryImageService.Record
        let mounts: [ContainerMountRecord]
        let links: [ManagedDataLinkRecord]
    }

    struct Metadata: Equatable {
        var helperPath: String?
        var image: AppLibraryImageService.Record?

        func matches(_ info: [String: Any]) -> Bool {
            guard info[helperKey] as? String == helperPath else { return false }
            guard let data = info[imageKey] as? Data else { return image == nil }
            return (try? JSONDecoder().decode(AppLibraryImageService.Record.self, from: data)) == image
        }

        func apply(to info: inout [String: Any]) throws {
            info[helperKey] = helperPath
            info[imageKey] = try image.map { try JSONEncoder().encode($0) }
        }
    }

    static func metadata(targetPath: String, identifier: String, previous: [String: Any]) throws -> Metadata {
        let store = ContainerMountStore.shared
        return try metadata(targetPath: targetPath, identifier: identifier, previous: previous,
            current: AppLibraryImageRecovery.loadRecord(), mounts: store.recordsStrict(), links: store.managedLinks(),
            helperURL: Bundle.main.executableURL ?? Bundle.main.bundleURL)
    }

    static func metadata(targetPath: String, identifier: String, previous: [String: Any],
                         current: AppLibraryImageService.Record?, mounts: [ContainerMountRecord],
                         links: [ManagedDataLinkRecord], helperURL: URL) throws -> Metadata {
        let saved = try (previous[imageKey] as? Data).map {
            try JSONDecoder().decode(AppLibraryImageService.Record.self, from: $0)
        }
        let appImage = [current, saved].compactMap { $0 }.first {
            contains(targetPath, in: $0.libraryPath ?? $0.mountPath)
        }
        let request = Request(identifier: identifier, targetPath: targetPath, image: appImage)
        guard !plans(for: request, current: current, mounts: mounts, links: links).isEmpty else {
            return Metadata()
        }
        // Browsing from a debug build must not replace a working portal with a temporary helper path.
        try AppInstallationLocation.require(helperURL)
        return Metadata(helperPath: helperURL.path, image: appImage)
    }

    static func contains(_ path: String, in root: String) -> Bool {
        let parent = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let child = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return parent.count > 1 && child.starts(with: parent)
    }

    static func plans(for request: Request, current: AppLibraryImageService.Record?,
                      mounts: [ContainerMountRecord], links: [ManagedDataLinkRecord]) -> [Plan] {
        var images: [AppLibraryImageService.Record] = []
        for image in [request.image, current].compactMap({ $0 }) {
            guard !images.contains(where: {
                $0.imagePath == image.imagePath || ($0.libraryPath ?? $0.mountPath) == (image.libraryPath ?? image.mountPath)
            }) else { continue }
            images.append(image)
        }
        return images.compactMap { image in
            let root = image.libraryPath ?? image.mountPath
            let relatedMounts = mounts.filter {
                $0.bundleIdentifier == request.identifier && contains($0.externalRootPath, in: root)
            }
            let relatedLinks = links.filter {
                $0.bundleIdentifier == request.identifier && contains($0.destinationPath, in: root)
            }
            guard contains(request.targetPath, in: root) || !relatedMounts.isEmpty || !relatedLinks.isEmpty else { return nil }
            return Plan(image: image, mounts: relatedMounts, links: relatedLinks)
        }
    }

    struct Operations {
        var restoreImage: (AppLibraryImageService.Record) async throws -> AppLibraryImageService.Record
        var volumeUUIDs: (AppLibraryImageService.Record) async throws -> Set<String>
        var mountData: (ContainerMountRecord) async throws -> Void
        var verifyLink: (ManagedDataLinkRecord) async throws -> Void
    }

    /// The caller holds the operation lock and the portal retains its launch lease.
    static func execute(_ plans: [Plan], operations: Operations) async throws {
        for plan in plans {
            let restored = try await operations.restoreImage(plan.image)
            if !plan.mounts.isEmpty {
                let uuids = try await operations.volumeUUIDs(restored)
                for record in plan.mounts {
                    guard uuids.contains(record.volumeUUID.uppercased()) else { throw CocoaError(.fileReadUnknown) }
                    try await operations.mountData(record)
                }
            }
            for link in plan.links { try await operations.verifyLink(link) }
        }
    }

    static func readRequest(portal: URL) throws -> Request {
        let contents = portal.appendingPathComponent("Contents")
        let data = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleExecutable"] as? String == "launcher",
              let identifier = info["AppPortsTargetBundleIdentifier"] as? String, !identifier.isEmpty,
              info["CFBundleIdentifier"] as? String == identifier + ".appports.stub" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let path = try String(contentsOf: contents.appendingPathComponent("Resources/real_app_path.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path.utf8.count <= 32 * 1024,
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw CocoaError(.fileReadCorruptFile) }
        let image = try (info[imageKey] as? Data).map {
            try JSONDecoder().decode(AppLibraryImageService.Record.self, from: $0)
        }
        return Request(identifier: identifier, targetPath: path, image: image)
    }

    static func prepare(_ request: Request, store: ContainerMountStore = .shared) async throws -> Bool {
        // Inspect only local records before deciding whether this request concerns images.
        let initial = plans(for: request, current: AppLibraryImageRecovery.loadRecord(),
                            mounts: try store.recordsStrict(), links: try store.managedLinks())
        guard !initial.isEmpty else { return false }
        try WriterAdmission.registerCurrentWriter()
        let lock = OperationLock()
        guard await lock.acquire(timeout: 5) else { throw lock.diagnosticFailure(scope: .global) }
        defer { lock.release() }
        // A migration or the login agent may have changed records while we waited.
        let latest = plans(for: request, current: AppLibraryImageRecovery.loadRecord(),
                           mounts: try store.recordsStrict(), links: try store.managedLinks())
        let service = AppLibraryImageService(runner: LaunchCommandRunner())
        let migrator = ContainerVolumeMigrator(disk: DiskUtility(runner: LaunchCommandRunner(), administratorRunner: nil), store: store)
        let ejection = try DiskEjectionPauseStore(store: store).snapshot()
        do {
            try await execute(latest, operations: Operations(
                restoreImage: { try await AppLibraryImageRecovery.restoreForLaunch($0, service: service, ejection: ejection) },
                volumeUUIDs: { try await service.volumeUUIDs(in: $0) },
                mountData: { record in
                    try await migrator.mount(record: record)
                    try await migrator.requireExpectedVolume(record.volumeUUID, at: record.mountPointURL)
                },
                verifyLink: { link in
                    let original = URL(fileURLWithPath: link.originalPath)
                    let raw = try FileManager.default.destinationOfSymbolicLink(atPath: original.path)
                    let destination = URL(fileURLWithPath: raw, relativeTo: original.deletingLastPathComponent()).standardizedFileURL
                    guard destination.path == link.destinationPath else { throw CocoaError(.fileReadUnknown) }
                    let result = try await service.files.inspect(.source(.init(imageURL: destination)))
                    guard result.value == true,
                          let expectedUUID = link.destinationIdentity.volumeUUID,
                          result.uuid?.caseInsensitiveCompare(expectedUUID) == .orderedSame else {
                        throw CocoaError(.fileReadUnknown)
                    }
                }))
            return true
        } catch let pending as ShellCommandUnconfirmedTermination {
            // A timed-out writer still owns the operation lock until it exits.
            while (try? ProcessCommandRunner.isRunning(pending.process)) != false {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            throw pending
        }
    }

    /// Bounded commands, no administrator or credential prompts during application launch.
    private struct LaunchCommandRunner: ShellCommandRunning {
        private let deadline = ProcessInfo.processInfo.systemUptime + 45
        init() {}
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CocoaError(.fileReadUnknown) }
            let result = try await ProcessCommandRunner(captureLimit: 4 * 1024 * 1024)
                .run(executable: executable, arguments: arguments, timeout: min(timeout, remaining, 20))
            if let process = result.runningProcess { throw ShellCommandUnconfirmedTermination(process: process) }
            return result
        }
    }

    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().first == argument else { return }
        guard CommandLine.arguments.count == 3 else { exit(1) }
        let portal = URL(fileURLWithPath: CommandLine.arguments[2])
        Task.detached {
            do {
                let request = try readRequest(portal: portal)
                let handled = try await prepare(request)
                exit(handled ? 0 : 2)
            } catch {
                AppLogger.shared.logError("启动应用前接回映像失败", error: error)
                exit(1)
            }
        }
        dispatchMain()
    }
}
