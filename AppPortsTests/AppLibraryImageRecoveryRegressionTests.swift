import Foundation
import Testing
@testable import AppPorts

private struct LegacyImageRunner: ShellCommandRunning {
    let imagePath: String
    let actualUUID: String

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        let value: [String: Any]
        if executable == "/usr/bin/hdiutil", arguments == ["info", "-plist"] {
            value = ["images": [["image-path": imagePath, "system-entities": [
                ["dev-entry": "/dev/disk99s1", "mount-point": "/Volumes/Apps"]]]]]
        } else if executable == "/usr/sbin/diskutil", arguments == ["info", "-plist", "/dev/disk99s1"] {
            value = ["FilesystemType": "apfs", "MountPoint": "/Volumes/Apps",
                "VolumeUUID": actualUUID, "WritableVolume": true]
        } else {
            Issue.record("The fixture must never attach an image")
            throw CocoaError(.featureUnsupported)
        }
        return ShellCommandResult(status: 0,
            standardOutput: try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
            standardError: Data(), timedOut: false)
    }
}

private struct StalledImageReader: ShellCommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        #expect(timeout == 10)
        #expect(arguments.first == AppLibraryImageFileAccess.launchArgument)
        return ShellCommandResult(status: -1, standardOutput: Data(), standardError: Data(), timedOut: true,
            runningProcess: .init(processIdentifier: 999999, startSeconds: 1, startMicroseconds: 1))
    }
}

struct AppLibraryImageRecoveryRegressionTests {
    @Test(arguments: [true, false])
    func legacyStorageIdentityIsPublishedOnlyAfterAPFSVerification(matches: Bool) async throws {
        let suite = "ImageRecoveryRegression-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var original = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/USB/Apps.sparsebundle"))
        let expected = UUID().uuidString
        original.volumeUUID = expected
        original.libraryPath = "/Volumes/Apps"
        try AppLibraryImageRecovery.save(original, defaults: defaults)
        defaults.set(original.libraryPath, forKey: "ExternalDrivePath")
        let runner = LegacyImageRunner(imagePath: original.imagePath, actualUUID: matches ? expected : UUID().uuidString)
        let files = AppLibraryImageFileAccess(inspect: { request in
            switch request {
            case .source:
                return .init(uuid: "VOLUME-USB", value: true)
            case .capture(var record):
                #expect(matches, "An unverified image must never be used to capture storage identity")
                record.backingVolumeUUID = "VOLUME-USB"
                record.imageRelativePath = "Apps.sparsebundle"
                return .init(record: record)
            default:
                Issue.record("Unexpected filesystem query")
                throw CocoaError(.featureUnsupported)
            }
        })
        let service = AppLibraryImageService(runner: runner, mountedUUID: { _ in expected }, files: files)
        await AppLibraryImageRecovery.recoverSelected(defaults: defaults, service: service, runner: runner)
        let saved = try #require(AppLibraryImageRecovery.selectedRecord(defaults: defaults))
        if matches {
            #expect(saved.backingVolumeUUID == "VOLUME-USB")
            #expect(saved.imageRelativePath == "Apps.sparsebundle")
        } else {
            #expect(saved == original)
        }
    }

    @Test func stalledReadDoesNotBecomeAnUnconfirmedWriter() async {
        do {
            _ = try await AppLibraryImageFileAccess.query(.mountedUUID("/fixture/Apps"),
                runner: StalledImageReader(), executable: URL(fileURLWithPath: "/fixture/AppPorts"))
            Issue.record("Timed-out metadata must be rejected")
        } catch {
            #expect(!(error is ShellCommandUnconfirmedTermination))
        }
    }

    @Test @MainActor func foregroundReloadsRecordRebasedByTheAgent() throws {
        let suite = "ImageControllerRegression-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/OldShare/Apps.sparsebundle"))
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        let controller = AppLibraryImageController(defaults: defaults)
        record.imagePath = "/fixture/NewShare/Apps.sparsebundle"
        record.networkShareURL = "smb://nas.local/Apps"
        record.imageRelativePath = "Apps.sparsebundle"
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        controller.reloadRecord()
        #expect(controller.record == record)
    }

    @Test func selectionReconciliationReadsPreferencesAfterTheOperationLock() async throws {
        let suite = "ImageSelectionRegression-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let lockURL = root.appendingPathComponent("operation.lock")
        let blocker = OperationLock(fileURL: lockURL, writerAdmissionCheck: {})
        try #require(blocker.tryAcquire())
        defer { blocker.release() }
        let waiter = OperationLock(fileURL: lockURL, writerAdmissionCheck: {})
        let task = Task {
            await ContainerMountAgentInstaller.synchronizeSelection(lock: waiter, synchronize: {
                let currentDefaults = UserDefaults(suiteName: suite)!
                let selected = AppLibraryImageRecovery.selectedRecord(defaults: currentDefaults)
                #expect(selected != nil)
                let payload = ContainerMountAgentInstaller.launchAgentPayload(executablePath: "/fixture/AppPorts",
                    recoverImages: selected != nil)
                #expect(payload["StartInterval"] as? Int == 60)
            })
        }
        defer { task.cancel() }
        let record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/USB/Apps.sparsebundle"))
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        defaults.set(record.mountPath, forKey: "ExternalDrivePath")
        defaults.synchronize()
        blocker.release()
        await task.value
    }
}


private struct ThrowingImageReader: ShellCommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        throw ShellCommandUnconfirmedTermination(process: .init(processIdentifier: 999999,
            startSeconds: 1, startMicroseconds: 1))
    }
}

private actor ImageAttachFixture: ShellCommandRunning {
    let image: String
    let uuid = UUID().uuidString
    private var attached = false
    private var failPostAttachRead: Bool
    private let allowMount: Bool
    private(set) var attachCount = 0
    private(set) var detached = false
    private(set) var mounted = false
    init(image: String, initiallyAttached: Bool = false, failPostAttachRead: Bool = false, allowMount: Bool = false) {
        self.image = image
        attached = initiallyAttached
        self.failPostAttachRead = failPostAttachRead
        self.allowMount = allowMount
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        var value: [String: Any] = [:]
        if arguments == ["info", "-plist"] {
            if attached, failPostAttachRead {
                failPostAttachRead = false
                throw CocoaError(.fileReadUnknown)
            }
            value = ["images": attached ? [["image-path": image, "system-entities": [
                ["dev-entry": "/dev/disk99"],
                ["dev-entry": "/dev/disk99s1", "content-hint": "Apple_APFS"]]]] : []]
        } else if arguments == ["apfs", "list", "-plist"] {
            var volume = ["DeviceIdentifier": "disk100s1"]
            if mounted { volume["MountPoint"] = "/Volumes/Apps" }
            value = ["Containers": [["PhysicalStores": [["DeviceIdentifier": "disk99s1"]], "Volumes": [volume]]]]
        } else if arguments == ["image", "attach", "--help"] {
            return ShellCommandResult(status: 0, standardOutput: Data("--noMount".utf8), standardError: Data(), timedOut: false)
        } else if arguments.first == "image", arguments.contains("attach") {
            #expect(arguments.contains("--noMount"))
            attached = true
            attachCount += 1
        } else if arguments.first == "info", arguments.count == 3 {
            value = arguments.last == "/dev/disk100s1"
                ? ["FilesystemType": "apfs", "VolumeUUID": uuid, "WritableVolume": true] : [:]
            if mounted, arguments.last == "/dev/disk100s1" { value["MountPoint"] = "/Volumes/Apps" }
        } else if arguments == ["detach", "/dev/disk99"] {
            detached = true
            attached = false
        } else if arguments.first == "mount" {
            mounted = true
            #expect(allowMount, "An unverified image must never be mounted")
            #expect(arguments == ["mount", "-mountPoint", "/Volumes/Apps", "/dev/disk100s1"])
        } else {
            Issue.record("Unexpected command")
            throw CocoaError(.featureUnsupported)
        }
        return ShellCommandResult(status: 0,
            standardOutput: try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
            standardError: Data(), timedOut: false)
    }
}

private actor AgentSyncGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

extension AppLibraryImageRecoveryRegressionTests {
    @Test func thrownReadTerminationDoesNotBecomeAnUnconfirmedWriter() async {
        do {
            _ = try await AppLibraryImageFileAccess.readCommand(runner: ThrowingImageReader(),
                executable: "/fixture/read", arguments: [], timeout: 10)
            Issue.record("An unfinished read must fail")
        } catch { #expect(!(error is ShellCommandUnconfirmedTermination)) }
    }

    @Test(arguments: [false, true])
    func mismatchedUnmountedAPFSIsDetachedBeforeItCanOccupyLibraryPath(initiallyAttached: Bool) async throws {
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/Apps.sparsebundle"))
        record.volumeUUID = UUID().uuidString
        let runner = ImageAttachFixture(image: record.imagePath, initiallyAttached: initiallyAttached)
        let files = AppLibraryImageFileAccess(inspect: { request in
            switch request {
            case .source: return .init(value: true)
            case .occupied: return .init(value: false)
            default: throw CocoaError(.featureUnsupported)
            }
        })
        do {
            _ = try await AppLibraryImageService(runner: runner, files: files).mount(record)
            Issue.record("Mismatched UUID must fail")
        } catch { #expect(!(error is ShellCommandUnconfirmedTermination)) }
        #expect(await runner.detached == !initiallyAttached)
        #expect(await !runner.mounted)
    }

    @Test @MainActor func quitWaitsForSelectionReconciliation() async {
        let gate = AgentSyncGate()
        let sync = AppLibraryAgentSync(synchronize: { await gate.wait() })
        sync.selectionDidChange()
        while !(await gate.started) { await Task.yield() }
        var replied = false
        let waiting = sync.finishBeforeTerminating { completed in
            #expect(completed)
            replied = true
        }
        #expect(waiting)
        #expect(!replied)
        await gate.release()
        while !replied { await Task.yield() }
        #expect(!sync.finishBeforeTerminating { _ in })
    }

    @Test func inventoryFailureCanResumeWithoutAttachingASecondWriter() async throws {
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/Apps.sparsebundle"))
        let runner = ImageAttachFixture(image: record.imagePath, failPostAttachRead: true, allowMount: true)
        let uuid = runner.uuid
        record.volumeUUID = uuid
        let files = AppLibraryImageFileAccess(inspect: { request in
            switch request {
            case .source: return .init(value: true)
            case .occupied: return .init(value: false)
            case .capture(let record): return .init(record: record)
            default: throw CocoaError(.featureUnsupported)
            }
        })
        let service = AppLibraryImageService(runner: runner, mountedUUID: { _ in uuid }, files: files)
        do {
            _ = try await service.mount(record)
            Issue.record("The first inventory read must fail")
        } catch { #expect(!(error is ShellCommandUnconfirmedTermination)) }
        let result = try await service.mount(record)
        #expect(result.record.volumeUUID == uuid)
        #expect(result.libraryURL.path == "/Volumes/Apps")
        #expect(await runner.attachCount == 1)
        #expect(await runner.mounted)
        #expect(await !runner.detached)
    }

    @Test func existingUnmountedImageWithoutSavedUUIDIsNotAdopted() async {
        let record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/Apps.sparsebundle"))
        let runner = ImageAttachFixture(image: record.imagePath, initiallyAttached: true)
        let files = AppLibraryImageFileAccess(inspect: { request in
            guard case .source = request else { throw CocoaError(.featureUnsupported) }
            return .init(value: true)
        })
        do {
            _ = try await AppLibraryImageService(runner: runner, files: files).mount(record)
            Issue.record("An unknown attachment must not be adopted")
        } catch { }
        #expect(await runner.attachCount == 0)
        #expect(await !runner.mounted)
        #expect(await !runner.detached)
    }

    @Test @MainActor func quitDeadlineRepliesOnceAndLeavesConfigurationRunning() async {
        let gate = AgentSyncGate()
        let sync = AppLibraryAgentSync(synchronize: { await gate.wait() })
        sync.selectionDidChange()
        while !(await gate.started) { await Task.yield() }
        var replies: [Bool] = []
        #expect(sync.finishBeforeTerminating(timeout: 0) { replies.append($0) })
        while replies.isEmpty { await Task.yield() }
        #expect(replies == [false])
        await gate.release()
        var finished = false
        if !sync.finishBeforeTerminating({ finished = $0 }) { finished = true }
        while !finished { await Task.yield() }
        #expect(replies == [false])
    }
}
