import Darwin
import Foundation
import Testing
@testable import AppPorts

struct SignatureMountBoundaryTests {
    @Test("Signature copy and cleanup never enter a real volume mounted inside a bundle")
    func nestedAPFSVolumeIsPreserved() async throws {
        let image = try MountedFixture()
        do {
            try await image.prepare()
            let app = image.app
            let nested = image.mountPoint
            // Capture an ordinary old deletion record before another volume
            // appears at its child path. It must not acquire that volume.
            let oldManifest = try SignatureRemovalManifest.capture(at: app)
            try await image.attach()
            let unrelated = nested.appendingPathComponent("volume-owned-document")
            let payload = Data("This belongs to the separately mounted volume".utf8)
            try payload.write(to: unrelated)
            let volumeIdentity = try DataPathIdentity.capture(nested)
            let documentIdentity = try DataPathIdentity.capture(unrelated)

            #expect(throws: TreeCopyError.self) { try SignatureSnapshot.items(in: app) }
            #expect(throws: TreeCopyError.self) { try SignatureSnapshot.fingerprint(of: app) }
            #expect(throws: TreeCopyError.self) { try SignatureRemovalManifest.capture(at: app) }
            #expect(throws: TreeCopyError.self) { try SignatureRemovalManifest.capture(at: nested) }
            #expect(throws: TreeCopyError.self) { try oldManifest.remove(at: app, allowingPartial: true, unlockCopiedFlags: true) }
            #expect(throws: TreeCopyError.self) { try SignatureSnapshot.remove(app) }
            // The preflight rejects this before calling the operating system's
            // Trash API. The test never creates or empties real Trash items.
            #expect(throws: TreeCopyError.self) { try SignatureSnapshot.trash(app) }
            for cloning in [false, true] {
                let destination = image.root.appendingPathComponent("Candidate-\(cloning).app")
                #expect(throws: TreeCopyError.self) {
                    try SignatureSnapshot.copy(from: app, to: destination, allowCloning: cloning)
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            }
            #expect(try Data(contentsOf: unrelated) == payload)
            #expect(try DataPathIdentity.capture(nested).matchesFilesystemObject(volumeIdentity))
            #expect(try DataPathIdentity.capture(unrelated).matchesFilesystemObject(documentIdentity))
            #expect(try String(contentsOf: app.appendingPathComponent("owned-document"), encoding: .utf8) == "original app data")

            try await image.detach()
            let fresh = try SignatureRemovalManifest.capture(at: app)
            try fresh.remove(at: app, allowingPartial: false, unlockCopiedFlags: true)
            #expect(!FileManager.default.fileExists(atPath: app.path))
            try await image.cleanup()
        } catch {
            // Never recursively clean a fixture while its test volume remains
            // mounted; detach failure leaves the complete fixture for diagnosis.
            try await image.cleanup()
            throw error
        }
    }

    private actor MountedFixture {
        nonisolated let root: URL
        nonisolated let app: URL
        nonisolated let mountPoint: URL
        private let image: URL
        private var attached = false
        private var devicePath: String?

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsSignatureMount-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            app = root.appendingPathComponent("Original.app")
            mountPoint = app.appendingPathComponent("Contents/Resources/SeparateVolume")
            image = root.appendingPathComponent("fixture.dmg")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try Data("original app data".utf8).write(to: app.appendingPathComponent("owned-document"))
        }

        func prepare() async throws {
            _ = try await run(["create", "-size", "64m", "-fs", "APFS", "-volname", "AppPortsSignatureMount", image.path])
        }

        func attach() async throws {
            let result = try await run(["attach", "-plist", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
            attached = true
            devicePath = Self.attachedDevicePath(in: result.standardOutput)
            try #require(DiskUtility.isMountPoint(mountPoint))
        }

        func detach() async throws {
            if attached || DiskUtility.isMountPoint(mountPoint) {
                _ = try await run(["detach", devicePath ?? mountPoint.path])
                attached = false
                devicePath = nil
            }
        }

        func cleanup() async throws {
            try await detach()
            try FileManager.default.removeItem(at: root)
        }

        private static func attachedDevicePath(in output: Data) -> String? {
            guard let plist = try? PropertyListSerialization.propertyList(from: output, options: [], format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]] else {
                return nil
            }
            return entities.compactMap { $0["dev-entry"] as? String }
                .first { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil }
        }

        private func run(_ arguments: [String]) async throws -> ShellCommandResult {
            let result = try await ProcessCommandRunner().run(executable: "/usr/bin/hdiutil", arguments: arguments, timeout: 60)
            try #require(result.status == 0 && !result.timedOut, "\(result.combinedText)")
            return result
        }
    }
}
