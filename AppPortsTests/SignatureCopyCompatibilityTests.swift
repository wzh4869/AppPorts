import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Signature copying with older libcopyfile capabilities")
struct SignatureCopyCompatibilityTests {
    enum Runtime: String, CaseIterable, Sendable {
        case earlyMacOS12, macOS13
        var rejected: Set<UInt32> {
            self == .earlyMacOS12 ? [UInt32(COPYFILE_STATE_BSIZE), UInt32(COPYFILE_STATE_FORBID_CROSS_MOUNT)]
                : [UInt32(COPYFILE_STATE_FORBID_CROSS_MOUNT)]
        }
    }

    @Test("Missing options 13/14 preserve content, links, locks, ACLs, sparse data and resource forks", arguments: Runtime.allCases)
    func legacyCapabilitiesPreserveBundleMetadata(runtime: Runtime) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = fixture.resources.appendingPathComponent("payload")
        try writePayload(payload, megabytes: 3)
        try #require(chmod(payload.path, 0o640) == 0)
        try setAttribute("org.appports.compatibility", Data([0, 255, 33]), at: payload)
        try setAttribute("org.appports.empty", Data(), at: payload)
        try setAttribute("com.apple.cs.compatibility", Data("script signature bytes".utf8), at: payload)
        try setAttribute("com.apple.FinderInfo", Data(repeating: 0, count: 32), at: payload)
        try writeResourceFork(payload, megabytes: 3)
        try await run("/bin/chmod", ["+a", "everyone allow readattr,readextattr", payload.path])
        let internalLink = fixture.resources.appendingPathComponent("hardlink")
        let externalLink = fixture.root.appendingPathComponent("unselected-hardlink")
        try #require(link(payload.path, internalLink.path) == 0)
        try #require(link(payload.path, externalLink.path) == 0)
        try FileManager.default.createSymbolicLink(atPath: fixture.resources.appendingPathComponent("current").path,
                                                  withDestinationPath: "payload")
        let locked = fixture.resources.appendingPathComponent("locked")
        try Data("candidate-only unlock must remain possible".utf8).write(to: locked)
        try #require(chflags(locked.path, UInt32(UF_IMMUTABLE | UF_HIDDEN)) == 0)
        let sparse = fixture.resources.appendingPathComponent("sparse")
        try Data([1, 2, 3]).write(to: sparse)
        let file = try FileHandle(forWritingTo: sparse)
        try file.seek(toOffset: 16 * 1024 * 1024 - 3)
        try file.write(contentsOf: Data([4, 5, 6]))
        // APFS may eagerly allocate the intervening bytes on seek+write.
        // Establish a real source hole before asserting its preservation.
        var filesystem = statfs()
        try #require(fstatfs(file.fileDescriptor, &filesystem) == 0)
        let block = off_t(filesystem.f_bsize)
        try #require(block > 0 && block < 8 * 1024 * 1024)
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: block,
                               fp_length: 16 * 1024 * 1024 - 2 * block)
        try #require(fcntl(file.fileDescriptor, F_PUNCHHOLE, &hole) == 0)
        let firstSourceHole = lseek(file.fileDescriptor, 0, SEEK_HOLE)
        try file.close()
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let sourceIdentity = try DataPathIdentity.capture(fixture.app)
        let sourcePayload = try SignatureSnapshot.info(at: payload)
        let sourceSparse = try SignatureSnapshot.info(at: sparse)
        try #require(sourceSparse.st_blocks * 512 < sourceSparse.st_size / 2)
        try #require(firstSourceHole > 0 && firstSourceHole < sourceSparse.st_size)
        for cloning in [false, true] {
            let target = fixture.root.appendingPathComponent("Candidate-\(cloning).app")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let candidateIdentity = try DataPathIdentity.capture(target)
            let probe = StateProbe(rejected: runtime.rejected)
            try SignatureSnapshot.copyContents(from: fixture.app, into: target, allowCloning: cloning, stateSetter: probe.setter)
            #expect(probe.options.contains(UInt32(COPYFILE_STATE_BSIZE)))
            #expect(probe.options.contains(UInt32(COPYFILE_STATE_FORBID_CROSS_MOUNT)))
            #expect(try DataPathIdentity.capture(target).matchesFilesystemObject(candidateIdentity))
            #expect(try SignatureSnapshot.fingerprint(of: target) == original)
            let copied = target.appendingPathComponent("Contents/Resources/payload")
            #expect(try Data(contentsOf: copied) == Data(contentsOf: payload))
            #expect(try attribute("org.appports.compatibility", at: copied) == Data([0, 255, 33]))
            #expect(try attribute("org.appports.empty", at: copied).isEmpty)
            #expect(try aclText(copied) == aclText(payload))
            let copiedInfo = try SignatureSnapshot.info(at: copied)
            #expect(copiedInfo.st_ino != sourcePayload.st_ino && copiedInfo.st_nlink == 1)
            #expect(try SignatureSnapshot.info(at: target.appendingPathComponent("Contents/Resources/hardlink")).st_nlink == 1)
            #expect(try SignatureSnapshot.info(at: target.appendingPathComponent("Contents/Resources/locked")).st_flags == UInt32(UF_IMMUTABLE | UF_HIDDEN))
            let copiedSparse = try SignatureSnapshot.info(at: target.appendingPathComponent("Contents/Resources/sparse"))
            #expect(copiedSparse.st_size == sourceSparse.st_size)
            #expect(copiedSparse.st_blocks * 512 < copiedSparse.st_size / 2)
        }
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(sourceIdentity))
        #expect(try SignatureSnapshot.info(at: payload).st_ino == sourcePayload.st_ino)
        #expect(try SignatureSnapshot.info(at: payload).st_nlink == 3)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
    }

    @Test("An early kernel rejecting CLONE_ACL performs a complete bounded ordinary copy")
    func legacyKernelWithoutCloneACLFallsBackWithoutLosingMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = fixture.resources.appendingPathComponent("acl-payload")
        try writePayload(payload, megabytes: 3)
        try await run("/bin/chmod", ["+a", "everyone allow readattr,readextattr", payload.path])
        try #require(chflags(payload.path, UInt32(UF_IMMUTABLE | UF_HIDDEN)) == 0)
        let sourceInfo = try SignatureSnapshot.info(at: payload)
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let writes = Writes()
        let rejected = Writes()
        try SignatureCompatibilityCopy.copy(from: fixture.app, to: fixture.candidate, intoExistingRoot: false,
            allowCloning: true, onDataCopied: { url, copied in
                if url.lastPathComponent == payload.lastPathComponent { writes.append(copied) }
            }, cloneFile: { sourceFD, targetParent, targetName, flags in
                if flags & UInt32(CLONE_ACL) != 0 {
                    rejected.append(Int64(flags))
                    errno = EINVAL
                    return -1
                }
                return fclonefileat(sourceFD, targetParent, targetName, flags)
            })
        let target = fixture.candidate.appendingPathComponent("Contents/Resources/acl-payload")
        #expect(!rejected.values.isEmpty)
        #expect(writes.values.first == 1_048_576 && writes.values.last == 3 * 1_048_576)
        #expect(try aclText(target) == aclText(payload))
        #expect(try SignatureSnapshot.info(at: target).st_flags == sourceInfo.st_flags)
        #expect(try SignatureSnapshot.info(at: target).st_ino != sourceInfo.st_ino)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.candidate) == original)
        #expect(try SignatureSnapshot.info(at: payload).st_ino == sourceInfo.st_ino)
        #expect(try SignatureSnapshot.info(at: payload).st_flags == sourceInfo.st_flags)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
    }

    @Test("Legacy ordinary copies preserve a real compressed file's logical bytes and original representation", arguments: Runtime.allCases)
    func legacyCompressedSourceRemainsUsable(runtime: Runtime) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = fixture.resources.appendingPathComponent("compressed")
        try Data().write(to: payload)
        let compressed = Data([102, 112, 109, 99, 3, 0, 0, 0, 22, 0, 0, 0, 0, 0, 0, 0,
                               120, 156, 43, 174, 204, 43, 201, 72, 45, 201, 76, 86, 72, 203,
                               73, 76, 87, 72, 203, 172, 40, 41, 45, 74, 5, 0, 101, 116, 8, 189])
        try setAttribute("com.apple.decmpfs", compressed, at: payload)
        try #require(chflags(payload.path, UInt32(UF_COMPRESSED)) == 0)
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let probe = StateProbe(rejected: runtime.rejected)
        try SignatureSnapshot.copy(from: fixture.app, to: fixture.candidate, allowCloning: false, stateSetter: probe.setter)
        #expect(try Data(contentsOf: fixture.candidate.appendingPathComponent("Contents/Resources/compressed")) == Data("synthetic flag fixture".utf8))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.candidate) == original)
        #expect(try SignatureSnapshot.info(at: payload).st_flags & UInt32(UF_COMPRESSED) != 0)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
    }

    @Test("A real copied signature still verifies with either legacy capability set", arguments: Runtime.allCases)
    func legacyCandidateKeepsRealSignature(runtime: Runtime) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await run("/usr/bin/codesign", ["--force", "--sign", "-", fixture.app.path])
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fixture.app.path])
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let probe = StateProbe(rejected: runtime.rejected)
        try SignatureSnapshot.copy(from: fixture.app, to: fixture.candidate, allowCloning: false, stateSetter: probe.setter)
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fixture.candidate.path])
        #expect(try SignatureSnapshot.fingerprint(of: fixture.candidate) == original)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
    }

    @Test("Legacy ordinary copy cancels after one bounded write, cleans its partial root and retries", arguments: Runtime.allCases)
    func legacyCancellationCleansAndRetries(runtime: Runtime) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.resources.appendingPathComponent("000-first")
        let second = fixture.resources.appendingPathComponent("999-later")
        try writePayload(first, megabytes: 8)
        try writePayload(second, megabytes: 8)
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let identity = try DataPathIdentity.capture(fixture.app)
        try FileManager.default.createDirectory(at: fixture.candidate, withIntermediateDirectories: false)
        let candidateIdentity = try DataPathIdentity.capture(fixture.candidate)
        let writes = Writes()
        let probe = StateProbe(rejected: runtime.rejected)
        let task = Task {
            try SignatureSnapshot.copyContents(from: fixture.app, into: fixture.candidate, allowCloning: false, onDataCopied: { url, copied in
                guard url.lastPathComponent == first.lastPathComponent else { return }
                writes.append(copied)
                withUnsafeCurrentTask { $0?.cancel() }
            }, stateSetter: probe.setter)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(writes.values == [1_048_576])
        let partial = fixture.candidate.appendingPathComponent("Contents/Resources/000-first")
        #expect(try SignatureSnapshot.info(at: partial).st_size == 1_048_576)
        #expect(try !SignatureSnapshot.entryExists(fixture.candidate.appendingPathComponent("Contents/Resources/999-later")))
        #expect(try DataPathIdentity.capture(fixture.candidate).matchesFilesystemObject(candidateIdentity))
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(identity))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        try SignatureSnapshot.remove(fixture.candidate)
        #expect(try !SignatureSnapshot.entryExists(fixture.candidate))
        try SignatureSnapshot.copy(from: fixture.app, to: fixture.candidate, allowCloning: false, stateSetter: probe.setter)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.candidate) == original)
    }

    @Test("Replacing a source or claimed candidate while copying stops without a second copy", arguments: [false, true])
    func legacyReplacementStopsCopy(replaceCandidate: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.resources.appendingPathComponent("000-first")
        try writePayload(first, megabytes: 3)
        let renamed = fixture.root.appendingPathComponent("SavedRoot.app")
        let changed = replaceCandidate ? fixture.candidate : fixture.app
        try FileManager.default.createDirectory(at: fixture.candidate, withIntermediateDirectories: false)
        let mutation = OneShot()
        let writes = Writes()
        let probe = StateProbe(rejected: Runtime.earlyMacOS12.rejected)
        #expect(throws: CodeSigner.SigningError.self) {
            try SignatureSnapshot.copyContents(from: fixture.app, into: fixture.candidate, allowCloning: false, onDataCopied: { url, copied in
                guard url.lastPathComponent == first.lastPathComponent else { return }
                writes.append(copied)
                mutation.perform {
                    try FileManager.default.moveItem(at: changed, to: renamed)
                    try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
                    try Data("unrelated replacement must remain untouched".utf8).write(to: changed.appendingPathComponent("sentinel"))
                }
            }, stateSetter: probe.setter)
        }
        try mutation.rethrowFailure()
        #expect(writes.values == [1_048_576])
        #expect(try FileManager.default.contentsOfDirectory(atPath: changed.path) == ["sentinel"])
        #expect(try String(contentsOf: changed.appendingPathComponent("sentinel"), encoding: .utf8) == "unrelated replacement must remain untouched")
    }

    @Test("State setup I/O failure cannot become a legacy fallback or create a destination")
    func realStateFailureDoesNotDowngrade() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        do {
            try SignatureSnapshot.copy(from: fixture.app, to: fixture.candidate, stateSetter: { state, flag, value in
                if flag == UInt32(COPYFILE_STATE_BSIZE) { errno = EIO; return -1 }
                return copyfile_state_set(state, flag, value)
            })
            Issue.record("An I/O failure was misclassified as an unavailable option")
        } catch {
            #expect((error as NSError).domain == NSPOSIXErrorDomain)
            #expect((error as NSError).code == Int(EIO))
        }
        #expect(try !SignatureSnapshot.entryExists(fixture.candidate))
    }

    @Test("Current-runtime signature copying streams a real 256 MiB resource fork, cancels and retries")
    func currentRuntimeLargeForkUsesBoundedSignatureCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = fixture.resources.appendingPathComponent("large-fork")
        let data = Data("small logical data fork".utf8)
        try data.write(to: payload)
        try writeResourceFork(payload, megabytes: 256)
        try #require(getxattr(payload.path, ResourceForkStream.attributeName, nil, 0, 0, XATTR_NOFOLLOW) == 256 * 1_048_576)
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let sourceIdentity = try DataPathIdentity.capture(fixture.app)
        let sampler = try ResidentMemorySampler()
        defer { _ = sampler.finish() }
        // No capability is rejected: this exercises current-runtime routing,
        // including libcopyfile versions with both 13/14 but unbounded xattrs.
        let probe = StateProbe(rejected: [])
        try FileManager.default.createDirectory(at: fixture.candidate, withIntermediateDirectories: false)
        let candidateIdentity = try DataPathIdentity.capture(fixture.candidate)
        try SignatureSnapshot.copyContents(from: fixture.app, into: fixture.candidate, allowCloning: false, stateSetter: probe.setter)
        #expect(try DataPathIdentity.capture(fixture.candidate).matchesFilesystemObject(candidateIdentity))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.candidate) == original)
        let retry = fixture.root.appendingPathComponent("Retry.app")
        let writes = Writes()
        let task = Task {
            try SignatureSnapshot.copy(from: fixture.app, to: retry, allowCloning: false, onDataCopied: { url, copied in
                guard url.lastPathComponent == payload.lastPathComponent, copied > Int64(data.count) else { return }
                writes.append(copied)
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(writes.values == [Int64(data.count + 1_048_576)])
        let partial = retry.appendingPathComponent("Contents/Resources/large-fork")
        #expect(getxattr(partial.path, ResourceForkStream.attributeName, nil, 0, 0, XATTR_NOFOLLOW) == 1_048_576)
        try SignatureSnapshot.remove(retry)
        try SignatureSnapshot.copy(from: fixture.app, to: retry, allowCloning: false)
        #expect(try SignatureSnapshot.fingerprint(of: retry) == original)
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(sourceIdentity))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        let memory = sampler.finish()
        let evidence: [String: Any] = ["case": "signature-copy-resource-fork-256MiB", "pid": Int(getpid()),
            "forkBytes": 256 * 1_048_576, "residentBaselineBytes": memory.baseline,
            "sampledPeakResidentBytes": memory.peak, "sampledResidentIncreaseBytes": memory.peak - memory.baseline,
            "residentSamples": memory.samples, "sampleFailures": memory.failures, "samplingIntervalMilliseconds": 10,
            "scope": "SignatureSnapshot ordinary copying, verification, cancellation, cleanup and retry; fixture creation excluded"]
        let json = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        print("SIGNATURE_COPY_RESOURCE_FORK_VALIDATION \(String(decoding: json, as: UTF8.self))")
        #expect(memory.failures == 0 && memory.samples > 0)
        // Process sampling can miss a brief peak, and is not a measurement of
        // every allocation. The implementation's I/O buffers are separately
        // fixed at 1 MiB and the fork bytes never enter a manifest/Data value.
        #expect(memory.peak - memory.baseline < 128 * 1_048_576)
    }

    @Test("Legacy copy rejects a real APFS mount introduced after its initial scan")
    func legacyCopyRejectsMountIntroducedDuringCopy() async throws {
        let fixture = try Fixture()
        let image = fixture.root.appendingPathComponent("owned-test-image.dmg")
        let mount = fixture.resources.appendingPathComponent("999-mounted")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let first = fixture.resources.appendingPathComponent("000-first")
        try writePayload(first, megabytes: 2)
        try await run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "APFS", "-volname", "AppPortsLegacyCopy", image.path])
        let attach = OneShot()
        let attachedDeviceBox = NSLock()
        var attachedDevice: String?
        do {
            let probe = StateProbe(rejected: Runtime.earlyMacOS12.rejected)
            #expect(throws: TreeCopyError.self) {
                try SignatureSnapshot.copy(from: fixture.app, to: fixture.candidate, allowCloning: false, onDataCopied: { url, _ in
                    guard url.lastPathComponent == first.lastPathComponent else { return }
                    attach.perform {
                        let out = try runSynchronously("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-mountpoint", mount.path, image.path])
                        if let plist = try? PropertyListSerialization.propertyList(from: out, options: [], format: nil) as? [String: Any],
                           let entities = plist["system-entities"] as? [[String: Any]],
                           let dev = entities.compactMap({ $0["dev-entry"] as? String })
                               .first(where: { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil }) {
                            attachedDeviceBox.withLock { attachedDevice = dev }
                        }
                        try Data("separate volume remains untouched".utf8).write(to: mount.appendingPathComponent("sentinel"))
                    }
                }, stateSetter: probe.setter)
            }
            try attach.rethrowFailure()
            #expect(DiskUtility.isMountPoint(mount))
            #expect(try String(contentsOf: mount.appendingPathComponent("sentinel"), encoding: .utf8) == "separate volume remains untouched")
            #expect(try !SignatureSnapshot.entryExists(fixture.candidate.appendingPathComponent("Contents/Resources/999-mounted/sentinel")))
            let target = attachedDeviceBox.withLock { attachedDevice } ?? mount.path
            try await run("/usr/bin/hdiutil", ["detach", target])
            fixture.remove()
        } catch {
            // Failure to detach preserves this exact private fixture, avoiding
            // recursive deletion through a mounted filesystem during cleanup.
            let recordedDevice = attachedDeviceBox.withLock { attachedDevice }
            let target = recordedDevice ?? mount.path
            if recordedDevice != nil || DiskUtility.isMountPoint(mount) { try await run("/usr/bin/hdiutil", ["detach", target]) }
            fixture.remove()
            throw error
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let app: URL
        let candidate: URL
        let resources: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsCopyCompatibility-" + UUID().uuidString).resolvingSymlinksInPath()
            app = root.appendingPathComponent("Original.app")
            candidate = root.appendingPathComponent("Candidate.app")
            resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let macOS = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: false)
            let executable = macOS.appendingPathComponent("Fixture")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            guard chmod(executable.path, 0o755) == 0 else { throw POSIXError(.EIO) }
            let info: [String: String] = ["CFBundleIdentifier": "org.appports.compatibility.fixture", "CFBundleExecutable": "Fixture",
                                        "CFBundleName": "Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        func remove() {
            // Every path here is under this test's exclusive UUID root. Clear
            // its synthetic locks before removing it, never the user's files.
            for url in (try? SignatureSnapshot.items(in: root)) ?? [] {
                _ = lchflags(url.path, 0)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class StateProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let rejected: Set<UInt32>
        private var observed: [UInt32] = []
        init(rejected: Set<UInt32>) { self.rejected = rejected }
        var options: [UInt32] { lock.withLock { observed } }
        var setter: SignatureSnapshot.StateSetter {
            { [self] state, flag, value in set(state, flag, value) }
        }
        func set(_ state: copyfile_state_t, _ flag: UInt32, _ value: UnsafeRawPointer) -> Int32 {
            lock.withLock { observed.append(flag) }
            if rejected.contains(flag) { errno = EINVAL; return -1 }
            return copyfile_state_set(state, flag, value)
        }
    }
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int64] = []
        var values: [Int64] { lock.withLock { storage } }
        func append(_ value: Int64) { lock.withLock { storage.append(value) } }
    }
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var performed = false
        private var error: Error?
        func perform(_ body: () throws -> Void) {
            lock.withLock {
                guard !performed else { return }
                performed = true
                do { try body() } catch { self.error = error }
            }
        }
        func rethrowFailure() throws { try lock.withLock { if let error { throw error } } }
    }
    private func writePayload(_ url: URL, megabytes: Int) throws {
        try Data(repeating: 0xa5, count: 1_048_576).write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        for _ in 1..<megabytes { try file.write(contentsOf: Data(repeating: 0xa5, count: 1_048_576)) }
    }
    private func writeResourceFork(_ url: URL, megabytes: Int) throws {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        let bytes = Data(repeating: 0x5a, count: 1_048_576)
        for index in 0..<megabytes {
            try #require(bytes.withUnsafeBytes { fsetxattr(fd, ResourceForkStream.attributeName, $0.baseAddress, $0.count, UInt32(index * $0.count), 0) } == 0)
        }
    }
    private func setAttribute(_ name: String, _ data: Data, at url: URL) throws {
        try #require(data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } == 0)
    }
    private func attribute(_ name: String, at url: URL) throws -> Data {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        try #require(count >= 0)
        var bytes = Data(count: count)
        try #require(bytes.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } == count)
        return bytes
    }
    private func aclText(_ url: URL) throws -> String? {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { if errno == ENOENT { return nil }; throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 { return nil }
        guard let text = acl_to_text(acl, nil) else { throw POSIXError(.EIO) }
        defer { acl_free(text) }
        return String(cString: text)
    }
    private func run(_ executable: String, _ arguments: [String]) async throws {
        let result = try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: 60)
        try #require(result.status == 0 && !result.timedOut, "\(result.combinedText)")
    }
    @discardableResult
    private func runSynchronously(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outBytes = stdout.fileHandleForReading.readDataToEndOfFile()
        let errBytes = stderr.fileHandleForReading.readDataToEndOfFile()
        try #require(process.terminationStatus == 0, "\(String(decoding: outBytes + errBytes, as: UTF8.self))")
        return outBytes
    }
}
