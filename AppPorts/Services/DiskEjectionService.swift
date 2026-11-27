import AppKit
import Foundation

struct DiskEjectionService: Sendable {
    /// Wait briefly for transient background maintenance, mount-agent checks, or
    /// LaunchAgent synchronization before reporting the operation lock as busy.
    static let defaultLockWaitTimeout: TimeInterval = 5

    let disk: DiskUtility
    let pauses: DiskEjectionPauseStore
    let makeLock: @Sendable () -> OperationLock
    let lockWaitTimeout: TimeInterval
    let inventory: @Sendable () async throws -> ExternalDiskInventory
    let physicalState: @Sendable (String) -> PhysicalDiskState
    let mountedDevices: @Sendable () throws -> Set<String>
    let mountedVolumePath: @Sendable (URL) -> String?
    let requestFinderEject: @Sendable (URL) async throws -> Void
    let selectedImage: @Sendable () -> AppLibraryImageService.Record?
    let imageService: AppLibraryImageService

    init(disk: DiskUtility = DiskUtility(administratorRunner: nil), store: ContainerMountStore = .shared,
         lockWaitTimeout: TimeInterval = DiskEjectionService.defaultLockWaitTimeout,
         inventory: (@Sendable () async throws -> ExternalDiskInventory)? = nil,
         physicalState: @escaping @Sendable (String) -> PhysicalDiskState = { PhysicalDiskState.query($0) },
         mountedDevices: @escaping @Sendable () throws -> Set<String> = { Set(try DiskUtility.kernelMountTable().keys) },
         mountedVolumePath: @escaping @Sendable (URL) -> String? = { DiskUtility.mountedVolumePath(containing: $0) },
         requestFinderEject: @escaping @Sendable (URL) async throws -> Void = { try await Self.ejectUsingFinder($0) },
         selectedImage: @escaping @Sendable () -> AppLibraryImageService.Record? = { AppLibraryImageRecovery.selectedRecord() },
         imageService: AppLibraryImageService = AppLibraryImageService()) {
        self.disk = disk
        self.lockWaitTimeout = max(0, lockWaitTimeout)
        self.physicalState = physicalState
        self.mountedDevices = mountedDevices
        self.mountedVolumePath = mountedVolumePath
        self.pauses = DiskEjectionPauseStore(store: store)
        let lockURL = store.fileURLForDeletionAuthorization.deletingLastPathComponent().appendingPathComponent("operation.lock")
        self.makeLock = { OperationLock(fileURL: lockURL) }
        self.inventory = inventory ?? { try await disk.ejectionInventory() }
        self.requestFinderEject = requestFinderEject
        self.selectedImage = selectedImage
        self.imageService = imageService
    }

    private func resolvedVolumeTarget(for url: URL, in inventory: ExternalDiskInventory) -> String {
        if let mounted = mountedVolumePath(url), mounted != "/" {
            return mounted
        }
        let path = url.standardizedFileURL.path
        let matches = Set(inventory.disks.flatMap(\.mountPaths).filter { root in
            path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
        })
        if let longestLength = matches.map(\.count).max() {
            let longest = matches.filter { $0.count == longestLength }
            if longest.count == 1, let root = longest.first {
                return root
            }
        }
        return path
    }

    enum RequestOutcome: Equatable, Sendable {
        case imageUnmounted
        case physicalDiskRequested(DiskEjectionPauseStore.Pause)
    }

    /// Finder's eject event is asynchronous: returning is not proof of ejection.
    /// Keep the durable pause on every post-publication outcome, including denial.
    @discardableResult
    func request(at url: URL?, retrying pauseID: UUID? = nil) async throws -> RequestOutcome {
        let lock = makeLock()
        guard await lock.acquire(timeout: lockWaitTimeout) else {
            try Task.checkCancellation()
            throw lock.admissionFailureReason.map { DiskEjectionError.finder($0) } ?? .busy
        }
        defer { lock.release() }
        if pauseID == nil, let url, let image = selectedImage(),
           PortalImageLaunchPreparation.contains(url.path, in: image.libraryPath ?? image.mountPath) {
            try await imageService.unmount(image, pauses: pauses)
            AppLogger.shared.log("应用库映像已卸载，自动挂载保持暂停", level: "INFO")
            return .imageUnmounted
        }
        let inventory = try await inventory()
        let current = try pauses.reconcile(inventory)
        let target: ExternalDiskInventory.Disk
        if let pauseID {
            guard let pause = current.pauses.first(where: { $0.id == pauseID }),
                  let candidate = inventory.disks.first(where: { $0.connectionID == pause.connectionID }) else {
                throw DiskEjectionError.unavailable
            }
            target = candidate
        } else {
            guard let url else { throw DiskEjectionError.unavailable }
            let volumeTarget = resolvedVolumeTarget(for: url, in: inventory)
            guard let uuid = try await disk.volumeInfo(for: volumeTarget).volumeUUID else {
                throw DiskEjectionError.unavailable
            }
            target = try inventory.disk(volumeUUID: uuid)
        }
        // Resolve an actually mounted member, even if an earlier attempt already
        // unmounted the visible base volume. Never fall back to a name or stale diskN.
        var member: (uuid: String, path: String)?
        for uuid in target.volumeUUIDs.sorted() {
            if let info = try? await disk.volumeInfo(for: uuid), let path = info.mountPoint, !path.isEmpty {
                member = (uuid, path)
                if url == nil || url?.path == path || url?.path.hasPrefix(path + "/") == true { break }
            }
        }
        guard let member else { throw DiskEjectionError.unavailable }
        let pause = try pauses.pause(target)
        let rechecked = try await self.inventory().disk(volumeUUID: member.uuid)
        let info = try await disk.volumeInfo(for: member.path)
        guard rechecked.connectionID == target.connectionID,
              info.volumeUUID?.uppercased() == member.uuid else { throw DiskEjectionError.unavailable }
        try await requestFinderEject(URL(fileURLWithPath: member.path))
        AppLogger.shared.log("已向 Finder 请求弹出外盘，自动挂载保持暂停", level: "INFO")
        return .physicalDiskRequested(pause)
    }

    static func ejectUsingFinder(_ url: URL) async throws {
        let path = AppMigrationService.appleScriptStringLiteral(url.path)
        let script = "tell application id \"com.apple.finder\" to eject (POSIX file \(path) as alias)"
        let result = try await ProcessCommandRunner().run(executable: "/usr/bin/osascript",
            arguments: ["-e", script], timeout: 60)
        guard result.status == 0 else { throw DiskEjectionError.finder(result.combinedText) }
    }
}

@MainActor
final class DiskEjectionController: ObservableObject {
    static let shared = DiskEjectionController()
    @Published private(set) var pauses: [DiskEjectionPauseStore.Pause] = []
    @Published private(set) var imagePauses: [DiskEjectionPauseStore.ImagePause] = []
    @Published private(set) var connectionStates: [String: PhysicalDiskState] = [:]
    @Published private(set) var isRequestingEjection = false
    /// Volume or directory roots currently being ejected so UI monitors, scans,
    /// and storage polling yield immediately before Finder unmounts the volume.
    @Published private(set) var activeEjectionPaths: Set<String> = []
    /// Incremented right before dispatching an ejection so active views cancel
    /// in-flight scans and close external monitors before Finder runs unmount.
    @Published private(set) var yieldRevision: UInt64 = 0
    private var availableDisks: [ExternalDiskInventory.Disk] = []
    var connected: Set<String> { Set(connectionStates.filter { $0.value == .online || $0.value == .unmounted }.map(\.key)) }
    @Published private(set) var isWorking = false
    @Published private(set) var needsRefresh = true
    @Published var errorMessage: String?
    private let service: DiskEjectionService
    private let operationState: AppOperationState
    private var revision: UInt64 = 0
    private var lastRefreshError: String?

    init(service: DiskEjectionService = DiskEjectionService(),
         operationState: AppOperationState? = nil) {
        self.service = service
        self.operationState = operationState ?? .shared
    }

    private var refreshing = false
    private var refreshAgain = false

    func state(for pause: DiskEjectionPauseStore.Pause) -> PhysicalDiskState {
        connectionStates[pause.connectionID] ?? .unknown
    }

    nonisolated static func standardizedPath(_ rawPath: String) -> String {
        let normalized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if normalized.count > 1, normalized.hasSuffix("/") {
            return String(normalized.dropLast())
        }
        return normalized
    }

    nonisolated static func path(_ candidate: String, isWithin root: String) -> Bool {
        let normalizedCandidate = standardizedPath(candidate)
        let normalizedRoot = standardizedPath(root)
        if normalizedCandidate == normalizedRoot { return true }
        guard normalizedRoot != "/" else { return normalizedCandidate.hasPrefix("/") }
        return normalizedCandidate.hasPrefix(normalizedRoot + "/")
    }

    /// Reads only the in-memory kernel mount table (`getmntinfo_r_np`) without opening
    /// or stating any path on the target volume.
    nonisolated static func mountedExternalVolumeRoot(for url: URL) -> String? {
        guard let table = try? DiskUtility.kernelMountTable() else { return nil }
        let candidate = standardizedPath(url.path)
        return table.values
            .compactMap { root -> String? in
                let normalized = standardizedPath(root)
                guard normalized != "/", normalized != "/System/Volumes/Data",
                      path(candidate, isWithin: normalized) else { return nil }
                return normalized
            }
            .max(by: { $0.count < $1.count })
    }

    /// Returns true while the volume containing `url` is actively being ejected or
    /// carries an unresumed ejection pause for that exact physical disk/image.
    func suppressesVolumeAccess(at url: URL?) -> Bool {
        guard let url else { return false }
        let candidate = Self.standardizedPath(url.path)
        if activeEjectionPaths.contains(where: { Self.path(candidate, isWithin: $0) || Self.path($0, isWithin: candidate) }) {
            return true
        }
        if imagePauses.contains(where: { image in
            Self.path(candidate, isWithin: image.imagePath)
                || image.mountPaths.contains { Self.path(candidate, isWithin: $0) }
        }) {
            return true
        }
        if let owner = uniqueAvailableDisk(containing: candidate) {
            return pauses.contains { $0.connectionID == owner.connectionID
                || !$0.volumeUUIDs.isDisjoint(with: owner.volumeUUIDs) }
        }
        return pauses.contains { pause in
            pause.mountPaths.contains { Self.path(candidate, isWithin: $0) }
        }
    }

    private func uniqueAvailableDisk(containing path: String) -> ExternalDiskInventory.Disk? {
        let owners = availableDisks.compactMap { disk -> (ExternalDiskInventory.Disk, Int)? in
            guard let length = disk.mountPaths.filter({ Self.path(path, isWithin: $0) }).map(\.count).max() else { return nil }
            return (disk, length)
        }
        guard let longest = owners.map(\.1).max() else { return nil }
        let candidates = owners.filter { $0.1 == longest }
        guard candidates.count == 1 else { return nil }
        return candidates[0].0
    }

    private func ejectionTargetPaths(at url: URL?, retrying pauseID: UUID?) -> Set<String> {
        var targets: Set<String> = []
        if let pauseID, let pause = pauses.first(where: { $0.id == pauseID }) {
            targets.formUnion(pause.mountPaths.map(Self.standardizedPath))
            if let disk = availableDisks.first(where: { $0.connectionID == pause.connectionID }) {
                targets.formUnion(disk.mountPaths.map(Self.standardizedPath))
            }
        }
        if let url {
            let normalized = Self.standardizedPath(url.path)
            targets.insert(normalized)
            if let root = Self.mountedExternalVolumeRoot(for: url) {
                targets.insert(root)
            } else if let root = service.mountedVolumePath(url), Self.standardizedPath(root) != "/" {
                targets.insert(Self.standardizedPath(root))
            }
            if let disk = uniqueAvailableDisk(containing: normalized) {
                targets.formUnion(disk.mountPaths.map(Self.standardizedPath))
            }
        }
        return targets
    }

    private func recordPublishedPause(_ pause: DiskEjectionPauseStore.Pause) {
        if let index = pauses.firstIndex(where: { $0.connectionID == pause.connectionID }) {
            pauses[index] = pause
        } else {
            pauses.append(pause)
        }
    }

    /// One eject action per disk. A replacement mounted at the same path is a
    /// different target and may still have its own initial eject action.
    func offersInitialEjection(at url: URL?) -> Bool {
        guard let url else { return false }
        let path = Self.standardizedPath(url.path)
        if let selected = uniqueAvailableDisk(containing: path) {
            return !pauses.contains { $0.connectionID == selected.connectionID
                || !$0.volumeUUIDs.isDisjoint(with: selected.volumeUUIDs) }
        }
        return !pauses.contains { $0.mountPaths.contains { Self.path(path, isWithin: $0) } }
    }

    func observeDisks() async {
        let monitor = PhysicalDiskMonitor()
        let changes = monitor.changes()
        defer { monitor.stop() }
        await refresh()
        for await _ in changes {
            guard !Task.isCancelled else { break }
            await refresh()
        }
    }

    private struct Observation: Sendable {
        let pauses: [DiskEjectionPauseStore.Pause]
        let imagePauses: [DiskEjectionPauseStore.ImagePause]
        let states: [String: PhysicalDiskState]
        let disks: [ExternalDiskInventory.Disk]
        let needsRetry: Bool
        let error: String?
    }

    func refresh() async {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            let revision = revision
            let service = service
            do {
                let result = try await Task.detached(priority: .utility) { () -> Observation in
                    let lock = service.makeLock()
                    let acquired = lock.tryAcquire()
                    defer { if acquired { lock.release() } }
                    var saved = try service.pauses.snapshot()
                    var inventory: ExternalDiskInventory?
                    var errorMessage: String?
                    // Never reconcile a new intent against a pre-lock inventory.
                    // A busy writer only prevents reconciliation, not observation.
                    if acquired, !saved.pauses.isEmpty {
                        do {
                            let current = try await service.inventory()
                            inventory = current
                            saved = try service.pauses.reconcile(current)
                        } catch { errorMessage = error.localizedDescription }
                    }
                    var mounts: Set<String>?
                    if !saved.pauses.isEmpty {
                        do { mounts = try service.mountedDevices() }
                        catch { errorMessage = errorMessage ?? error.localizedDescription }
                    }
                    let states = Dictionary(uniqueKeysWithValues: saved.pauses.map { pause in
                        let direct = service.physicalState(pause.connectionID)
                        let disk = inventory?.disks.first { $0.connectionID == pause.connectionID }
                        let physical = direct == .unknown && disk != nil ? PhysicalDiskState.online : direct
                        return (pause.connectionID, PhysicalDiskState.observed(physical: physical, disk: disk, mountedDevices: mounts))
                    })
                    return Observation(pauses: saved.pauses, imagePauses: saved.images, states: states, disks: inventory?.disks ?? [],
                        needsRetry: !acquired || errorMessage != nil || states.values.contains(.unknown), error: errorMessage)
                }.value
                guard revision == self.revision else { refreshAgain = true; continue }
                pauses = result.pauses
                imagePauses = result.imagePauses
                connectionStates = result.states
                availableDisks = result.disks
                needsRefresh = result.needsRetry
                if let message = result.error, message != lastRefreshError {
                    AppLogger.shared.log("外盘状态查询失败，保留暂停并等待设备重新连接：\(message)", level: "WARN")
                }
                lastRefreshError = result.error
            } catch {
                guard revision == self.revision else { refreshAgain = true; continue }
                connectionStates = [:]
                needsRefresh = true
                errorMessage = error.localizedDescription
            }
        } while refreshAgain && !Task.isCancelled
    }

    func eject(at url: URL?, retrying pauseID: UUID? = nil) {
        guard !isWorking, let token = operationState.begin() else { return }
        revision &+= 1
        needsRefresh = true
        isWorking = true
        isRequestingEjection = true
        activeEjectionPaths = ejectionTargetPaths(at: url, retrying: pauseID)
        yieldRevision &+= 1
        let service = service
        let operationState = operationState
        operationState.startTask(for: token) { [weak self] in
            var publishRecordsChange = false
            let requestTask = Task.detached { try await service.request(at: url, retrying: pauseID) }
            do {
                let outcome = try await withTaskCancellationHandler {
                    try await requestTask.value
                } onCancel: {
                    requestTask.cancel()
                }
                switch outcome {
                case .imageUnmounted:
                    publishRecordsChange = true
                case .physicalDiskRequested(let pause):
                    // Finder's eject event is asynchronous: do not publish recordsRevision here,
                    // or UI observers will immediately rescan the volume Finder is unmounting.
                    publishRecordsChange = false
                    self?.recordPublishedPause(pause)
                }
            } catch is CancellationError {
                publishRecordsChange = false
            } catch DiskEjectionError.busy {
                publishRecordsChange = false
                self?.errorMessage = DiskEjectionError.busy.localizedDescription
                AppLogger.shared.logError("外盘弹出请求未完成", error: DiskEjectionError.busy, errorCode: "DISK-EJECT-FAILED")
            } catch {
                publishRecordsChange = false
                if let snapshot = try? service.pauses.snapshot() {
                    self?.pauses = snapshot.pauses
                    self?.imagePauses = snapshot.images
                }
                self?.errorMessage = error.localizedDescription
                AppLogger.shared.logError("外盘弹出请求未完成", error: error, errorCode: "DISK-EJECT-FAILED")
            }
            self?.activeEjectionPaths = []
            self?.isRequestingEjection = false
            self?.isWorking = false
            operationState.finish(token, publishRecordsChange: publishRecordsChange)
            await self?.refresh()
        }
    }

}
