import Darwin
import Foundation
import Testing
@testable import AppPorts

private actor VolumeCreationRunner: ShellCommandRunning {
    struct Invocation: Sendable { let executable: String; let arguments: [String] }
    var calls: [Invocation] = []
    let before: [String: any Sendable]
    let after: [String: any Sendable]
    let createStatus: Int32
    let timedOut: Bool
    init(before: [String: any Sendable], after: [String: any Sendable], createStatus: Int32 = 0, timedOut: Bool = false) {
        self.before = before; self.after = after; self.createStatus = createStatus; self.timedOut = timedOut
    }
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        calls.append(Invocation(executable: executable, arguments: arguments))
        if executable == DiskUtility.diskutilPath, Array(arguments.prefix(2)) == ["apfs", "addVolume"] {
            return ShellCommandResult(status: createStatus, standardOutput: Data(), standardError: Data("creation failed".utf8), timedOut: timedOut)
        }
        let queries = calls.filter { Array($0.arguments.prefix(3)) == ["apfs", "list", "-plist"] }.count
        let plist = queries == 1 ? before : after
        return ShellCommandResult(status: 0, standardOutput: try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0), standardError: Data(), timedOut: false)
    }
}

struct DiskUtilityCreationTests {
    @Test("Restore ownership updates preserve Finder and security flags", arguments: [false, true])
    func restoreOwnershipOptions(enabled: Bool) async throws {
        let runner = FakeDiskCommandRunner()
        let disk = DiskUtility(runner: runner, administratorRunner: nil)
        let flags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_NODEV | MNT_NOSUID | MNT_NOEXEC | MNT_RDONLY)
        try await disk.setOwnershipForRestore(mountPoint: URL(fileURLWithPath: "/synthetic/only"), originalFlags: flags, enabled: enabled)
        #expect(runner.calls.map(\.arguments) == [["-u", "-o", "nobrowse,rdonly,nodev,nosuid,noexec," + (enabled ? "owners" : "noowners"), "/synthetic/only"]])
    }

    private let containerUUID = "46F1B932-305F-481E-A5BA-F648DD9CB99D"
    private let oldUUID = "77213F03-9D48-478F-A91B-B48B6F05C6A0"
    private let newUUID = "65E246B0-FD8C-488A-BFA2-B5B4CD05B2CD"
    private func volume(_ uuid: String, _ device: String, _ name: String) -> [String: String] {
        ["APFSVolumeUUID": uuid, "DeviceIdentifier": device, "Name": name]
    }
    private func plist(_ volumes: [[String: String]], uuid: String? = nil, reference: String = "disk7") -> [String: any Sendable] {
        ["Containers": [container(volumes, uuid: uuid, reference: reference)]]
    }
    private func container(_ volumes: [[String: String]], uuid: String? = nil, reference: String = "disk7") -> [String: any Sendable] {
        ["ContainerReference": reference, "APFSContainerUUID": uuid ?? containerUUID, "Volumes": volumes]
    }

    @Test func cleanupToleratesAnUnrelatedDiskImageAttachedTwice() async throws {
        let imageUUID = "CFC06FE1-EF86-4CB2-9819-BBD6B34927C2"
        let images = [
            container([volume(newUUID, "disk11s1", "MetalToolchainCryptex")], uuid: imageUUID, reference: "disk11"),
            container([volume(newUUID, "disk13s1", "MetalToolchainCryptex")], uuid: imageUUID, reference: "disk13")
        ]
        let target = container([volume(oldUUID, "disk7s1", "Retained")])
        let present = images + [target]
        let lookup = DiskUtility(runner: VolumeCreationRunner(before: ["Containers": present], after: ["Containers": present]), administratorRunner: nil)
        #expect(try await lookup.apfsContainerUUID(containingVolume: oldUUID.lowercased()) == containerUUID)
        #expect(try await lookup.apfsVolumeIsPresent(oldUUID, inContainer: containerUUID.lowercased()))

        let absent = images + [container([])]
        let retry = DiskUtility(runner: VolumeCreationRunner(before: ["Containers": absent], after: ["Containers": absent]), administratorRunner: nil)
        #expect(try await retry.apfsVolumeIsPresent(oldUUID, inContainer: containerUUID) == false)
    }

    @Test(arguments: ["duplicate-container", "duplicate-volume", "duplicate-in-same-container"])
    func cleanupRejectsAmbiguousTargetIdentities(_ scenario: String) async throws {
        let target = volume(oldUUID, "disk7s1", "Retained")
        let containers: [[String: any Sendable]]
        switch scenario {
        case "duplicate-container":
            containers = [container([target]), container([], uuid: containerUUID.lowercased(), reference: "disk9")]
        case "duplicate-volume":
            containers = [container([target]), container([volume(oldUUID.lowercased(), "disk9s1", "Other")],
                uuid: "CFC06FE1-EF86-4CB2-9819-BBD6B34927C2", reference: "disk9")]
        default:
            containers = [container([target, volume(oldUUID.lowercased(), "disk7s2", "Other")])]
        }
        let inventory: [String: any Sendable] = ["Containers": containers]
        let disk = DiskUtility(runner: VolumeCreationRunner(before: inventory, after: inventory), administratorRunner: nil)
        await #expect(throws: DiskUtility.Failure.self) { try await disk.apfsContainerUUID(containingVolume: oldUUID) }
        await #expect(throws: DiskUtility.Failure.self) { try await disk.apfsVolumeIsPresent(oldUUID, inContainer: containerUUID) }
    }

    @Test func createsVolumeThroughDiskArbitrationAndFreshUUID() async throws {
        let existing = volume(oldUUID, "disk7s1", "NewName") // Name equality never proves creation.
        let runner = VolumeCreationRunner(before: plist([existing]), after: plist([existing, volume(newUUID, "disk7s2", "NewName")]))
        let disk = DiskUtility(runner: runner, administratorRunner: { _, _ in Issue.record("Creation must not invoke administrator fallback"); throw CocoaError(.userCancelled) })
        #expect(try await disk.createAPFSVolume(inContainer: "disk7", name: "NewName") == "disk7s2")
        let calls = await runner.calls
        #expect(calls.map(\.executable) == [DiskUtility.diskutilPath, DiskUtility.diskutilPath, DiskUtility.diskutilPath])
        #expect(calls.map(\.arguments) == [["apfs", "list", "-plist", "disk7"], ["apfs", "addVolume", "disk7", "APFS", "NewName", "-nomount"], ["apfs", "list", "-plist", "disk7"]])
    }
    @Test(arguments: ["same-name-only", "two-new", "changed-container", "wrong-name", "reused-device", "missing-old"])
    func refusesAmbiguousOrReboundCreation(_ scenario: String) async throws {
        let old = volume(oldUUID, "disk7s1", "Existing")
        var after = [old, volume(newUUID, "disk7s2", "NewName")]
        if scenario == "same-name-only" { after = [volume(oldUUID, "disk7s1", "NewName")] }
        if scenario == "two-new" { after.append(volume(UUID().uuidString, "disk7s3", "NewName")) }
        if scenario == "wrong-name" { after[1]["Name"] = "Other" }
        if scenario == "reused-device" { after[1]["DeviceIdentifier"] = "disk7s1" }
        if scenario == "missing-old" { after.removeFirst() }
        let runner = VolumeCreationRunner(before: plist([old]), after: plist(after, uuid: scenario == "changed-container" ? UUID().uuidString : nil))
        await #expect(throws: (any Error).self) { try await DiskUtility(runner: runner, administratorRunner: nil).createAPFSVolume(inContainer: "disk7", name: "NewName") }
        #expect(await runner.calls.filter { Array($0.arguments.prefix(2)) == ["apfs", "addVolume"] }.count == 1)
    }
    @Test func rejectsWrongContainerBeforeCreation() async throws {
        let runner = VolumeCreationRunner(before: plist([], reference: "disk8"), after: plist([]))
        await #expect(throws: (any Error).self) { try await DiskUtility(runner: runner, administratorRunner: nil).createAPFSVolume(inContainer: "disk7", name: "NewName") }
        #expect(await runner.calls.allSatisfy { $0.executable == DiskUtility.diskutilPath })
    }
    @Test(arguments: ["disk7s1", "/dev/disk7", "-A", "disk7\n"])
    func rejectsNonContainerDeviceArgumentsWithoutCommands(_ reference: String) async throws {
        let runner = VolumeCreationRunner(before: plist([]), after: plist([]))
        await #expect(throws: (any Error).self) { try await DiskUtility(runner: runner, administratorRunner: nil).createAPFSVolume(inContainer: reference, name: "NewName") }
        #expect(await runner.calls.isEmpty)
    }
    @Test(arguments: [false, true]) func failedCreationIsNeverRetriedOrElevated(_ timeout: Bool) async throws {
        let runner = VolumeCreationRunner(before: plist([]), after: plist([]), createStatus: 1, timedOut: timeout)
        let disk = DiskUtility(runner: runner, administratorRunner: { _, _ in Issue.record("Failed creation must not retry as administrator"); throw CocoaError(.userCancelled) })
        await #expect(throws: (any Error).self) { try await disk.createAPFSVolume(inContainer: "disk7", name: "NewName") }
        let calls = await runner.calls
        #expect(calls.filter { Array($0.arguments.prefix(2)) == ["apfs", "addVolume"] }.count == 1)
        #expect(calls.count == 2)
    }
}
