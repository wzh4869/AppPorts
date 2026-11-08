import AppKit
import Foundation

struct DiskEjectionService: Sendable {
    let disk: DiskUtility
    let pauses: DiskEjectionPauseStore
    let makeLock: @Sendable () -> OperationLock
    let inventory: @Sendable () async throws -> ExternalDiskInventory
    let physicalState: @Sendable (String) -> PhysicalDiskState
    let mountedDevices: @Sendable () throws -> Set<String>
    let requestFinderEject: @Sendable (URL) async throws -> Void
    let selectedImage: @Sendable () -> AppLibraryImageService.Record?
    let imageService: AppLibraryImageService

    init(disk: DiskUtility = DiskUtility(administratorRunner: nil), store: ContainerMountStore = .shared,
         inventory: (@Sendable () async throws -> ExternalDiskInventory)? = nil,
         physicalState: @escaping @Sendable (String) -> PhysicalDiskState = { PhysicalDiskState.query($0) },
         mountedDevices: @escaping @Sendable () throws -> Set<String> = { Set(try DiskUtility.kernelMountTable().keys) },
         requestFinderEject: @escaping @Sendable (URL) async throws -> Void = { try await Self.ejectUsingFinder($0) },
         selectedImage: @escaping @Sendable () -> AppLibraryImageService.Record? = { AppLibraryImageRecovery.selectedRecord() },
         imageService: AppLibraryImageService = AppLibraryImageService()) {
        self.disk = disk
        self.physicalState = physicalState
        self.mountedDevices = mountedDevices
        self.pauses = DiskEjectionPauseStore(store: store)
        let lockURL = store.fileURLForDeletionAuthorization.deletingLastPathComponent().appendingPathComponent("operation.lock")
        self.makeLock = { OperationLock(fileURL: lockURL) }
        self.inventory = inventory ?? { try await disk.ejectionInventory() }
        self.requestFinderEject = requestFinderEject
        self.selectedImage = selectedImage
        self.imageService = imageService
    }

    /// Finder's eject event is asynchronous: returning is not proof of ejection.
    /// Keep the durable pause on every post-publication outcome, including denial.
    func request(at url: URL?, retrying pauseID: UUID? = nil) async throws {
        let lock = makeLock()
        guard lock.tryAcquire() else {
            throw lock.admissionFailureReason.map { DiskEjectionError.finder($0) } ?? .busy
        }
        defer { lock.release() }
        if pauseID == nil, let url, let image = selectedImage(),
           PortalImageLaunchPreparation.contains(url.path, in: image.libraryPath ?? image.mountPath) {
            try await imageService.unmount(image, pauses: pauses)
            AppLogger.shared.log("应用库映像已卸载，自动挂载保持暂停", level: "INFO")
            return
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
            guard let url, let uuid = try await disk.volumeInfo(for: url.path).volumeUUID else {
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
                if url?.path == path || url?.path.hasPrefix(path + "/") == true { break }
            }
        }
        guard let member else { throw DiskEjectionError.unavailable }
        _ = try pauses.pause(target)
        let rechecked = try await self.inventory().disk(volumeUUID: member.uuid)
        let info = try await disk.volumeInfo(for: member.path)
        guard rechecked.connectionID == target.connectionID,
              info.volumeUUID?.uppercased() == member.uuid else { throw DiskEjectionError.unavailable }
        try await requestFinderEject(URL(fileURLWithPath: member.path))
        AppLogger.shared.log("已向 Finder 请求弹出外盘，自动挂载保持暂停", level: "INFO")
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
    private var availableDisks: [ExternalDiskInventory.Disk] = []
    var connected: Set<String> { Set(connectionStates.filter { $0.value == .online || $0.value == .unmounted }.map(\.key)) }
    @Published private(set) var isWorking = false
    @Published private(set) var needsRefresh = true
    @Published var errorMessage: String?
    private let service: DiskEjectionService
    private var revision: UInt64 = 0
    private var lastRefreshError: String?

    init(service: DiskEjectionService = DiskEjectionService()) { self.service = service }

    private var refreshing = false
    private var refreshAgain = false

    func state(for pause: DiskEjectionPauseStore.Pause) -> PhysicalDiskState {
        connectionStates[pause.connectionID] ?? .unknown
    }

    /// One eject action per disk. A replacement mounted at the same path is a
    /// different target and may still have its own initial eject action.
    func offersInitialEjection(at url: URL?) -> Bool {
        guard let url else { return false }
        func matches(_ root: String) -> Bool { url.path == root || url.path.hasPrefix(root + "/") }
        let owners = availableDisks.compactMap { disk -> (ExternalDiskInventory.Disk, Int)? in
            guard let length = disk.mountPaths.filter({ matches($0) }).map(\.count).max() else { return nil }
            return (disk, length)
        }
        if let longest = owners.map({ $0.1 }).max() {
            let candidates = owners.filter { $0.1 == longest }
            guard candidates.count == 1 else { return false }
            let selected = candidates[0].0
            return !pauses.contains { $0.connectionID == selected.connectionID
                || !$0.volumeUUIDs.isDisjoint(with: selected.volumeUUIDs) }
        }
        return !pauses.contains { $0.mountPaths.contains(where: matches) }
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
        guard !isWorking, let token = AppOperationState.shared.begin() else { return }
        revision &+= 1
        needsRefresh = true
        isWorking = true
        isRequestingEjection = true
        let service = service
        AppOperationState.shared.startTask(for: token) { [weak self] in
            do { try await Task.detached { try await service.request(at: url, retrying: pauseID) }.value }
            catch {
                self?.errorMessage = error.localizedDescription
                AppLogger.shared.logError("外盘弹出请求未完成", error: error, errorCode: "DISK-EJECT-FAILED")
            }
            self?.isRequestingEjection = false
            self?.isWorking = false
            AppOperationState.shared.finish(token)
            await self?.refresh()
        }
    }

}
