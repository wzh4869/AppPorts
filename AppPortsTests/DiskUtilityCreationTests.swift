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
        if executable == "/sbin/newfs_apfs" {
            return ShellCommandResult(status: createStatus, standardOutput: Data(), standardError: Data("kDAReturnNotPrivileged: not allowed by the invoking user".utf8), timedOut: timedOut)
        }
        let queries = calls.filter { $0.executable == DiskUtility.diskutilPath }.count
        let plist = queries == 1 ? before : after
        return ShellCommandResult(status: 0, standardOutput: try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0), standardError: Data(), timedOut: false)
    }
}

struct DiskUtilityCreationTests {
    private let containerUUID = "46F1B932-305F-481E-A5BA-F648DD9CB99D"
    private let oldUUID = "77213F03-9D48-478F-A91B-B48B6F05C6A0"
    private let newUUID = "65E246B0-FD8C-488A-BFA2-B5B4CD05B2CD"
    private func volume(_ uuid: String, _ device: String, _ name: String) -> [String: String] {
        ["APFSVolumeUUID": uuid, "DeviceIdentifier": device, "Name": name]
    }
    private func plist(_ volumes: [[String: String]], uuid: String? = nil, reference: String = "disk7") -> [String: any Sendable] {
        ["Containers": [["ContainerReference": reference, "APFSContainerUUID": uuid ?? containerUUID, "Volumes": volumes] as [String: any Sendable]]]
    }
    @Test func createsOwnedRootUsingOnlyAddModeAndFreshUUID() async throws {
        let existing = volume(oldUUID, "disk7s1", "NewName") // Name equality never proves creation.
        let runner = VolumeCreationRunner(before: plist([existing]), after: plist([existing, volume(newUUID, "disk7s2", "NewName")]))
        let disk = DiskUtility(runner: runner, administratorRunner: { _, _ in Issue.record("Creation must not invoke administrator fallback"); throw CocoaError(.userCancelled) })
        #expect(try await disk.createAPFSVolume(inContainer: "disk7", name: "NewName") == "disk7s2")
        let calls = await runner.calls
        #expect(calls.map(\.executable) == [DiskUtility.diskutilPath, "/sbin/newfs_apfs", DiskUtility.diskutilPath])
        #expect(calls.map(\.arguments) == [["apfs", "list", "-plist", "disk7"], ["-A", "-w", "-U", String(getuid()), "-G", String(getgid()), "-v", "NewName", "disk7"], ["apfs", "list", "-plist", "disk7"]])
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
        #expect(await runner.calls.filter { $0.executable == "/sbin/newfs_apfs" }.count == 1)
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
        #expect(calls.filter { $0.executable == "/sbin/newfs_apfs" }.count == 1)
        #expect(calls.count == 2)
    }
}
