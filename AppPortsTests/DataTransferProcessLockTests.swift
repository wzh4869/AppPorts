import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Migration record process lock", .serialized)
struct DataTransferProcessLockTests {
    @Test("An independent writer cannot overwrite durable state while another process owns its lock")
    func independentProcessExclusion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsStoreLock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("records.plist")
        let store = ContainerMountStore(fileURL: file)
        let first = record(at: root.appendingPathComponent("A"), uuid: "A")
        let second = record(at: root.appendingPathComponent("B"), uuid: "B")
        try store.upsert(first)
        let original = try Data(contentsOf: file)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('R',flush=True); sys.stdin.read()", file.appendingPathExtension("lock").path]
        let ready = Pipe()
        let input = Pipe()
        child.standardOutput = ready
        child.standardInput = input
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        for _ in 0..<2 {
            #expect(throws: ContainerMountStore.StoreError.self) { try store.upsert(second) }
            #expect(try Data(contentsOf: file) == original)
        }
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        try store.upsert(second)
        #expect(try store.recordsStrict().map(\.volumeUUID).sorted() == ["A", "B"])
    }

    @Test("A linked lock file is rejected without touching the target")
    func symlinkLockIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsStoreLockLink-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("records.plist")
        let target = root.appendingPathComponent("untouched")
        let bytes = Data("untouched".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: file.appendingPathExtension("lock"), withDestinationURL: target)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try ContainerMountStore(fileURL: file).upsert(record(at: root.appendingPathComponent("A"), uuid: "A"))
        }
        #expect(try Data(contentsOf: target) == bytes)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Dangling record links cannot become empty migration history", arguments: [false, true])
    func danglingRecordLinkIsRejected(parentLink: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsStoreDangling-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("absent")
        let link = root.appendingPathComponent(parentLink ? "directory-link" : "records.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        let file = parentLink ? link.appendingPathComponent("records.plist") : link
        let store = ContainerMountStore(fileURL: file)
        #expect(throws: ContainerMountStore.StoreError.self) { try store.recordsStrict() }
        #expect(throws: (any Error).self) { try store.upsert(record(at: root.appendingPathComponent("A"), uuid: "A")) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("A genuinely absent first-run store can create missing parent directories")
    func missingFirstRunParents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsStoreFirstRun-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one/two/records.plist")
        let store = ContainerMountStore(fileURL: file)
        #expect(try store.recordsStrict().isEmpty)
        try store.upsert(record(at: root.appendingPathComponent("A"), uuid: "A"))
        #expect(try store.recordsStrict().map(\.volumeUUID) == ["A"])
    }

    private func record(at path: URL, uuid: String) -> ContainerMountRecord {
        ContainerMountRecord(appName: "Synthetic", bundleIdentifier: "org.appports.synthetic.lock",
            dataDirType: DataDirType.containers.rawValue, mountPointPath: path.path,
            volumeUUID: uuid, volumeName: "Synthetic", externalRootPath: path.deletingLastPathComponent().path)
    }
}
