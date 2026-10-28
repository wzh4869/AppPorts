import Darwin
import XCTest
@testable import AppPorts

final class WriterAdmissionTests: XCTestCase {
    func testUnreadableUnrelatedProcessDoesNotAbortAValidWriter() throws {
        let current = try WriterAdmission.currentProcessIdentity()
        let other = getppid()
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        XCTAssertEqual(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size), size)
        let snapshot = try WriterAdmission.runningAppPortsProcesses(processIDs: [getpid(), other]) { pid in
            pid == getpid() ? (info, current.executablePath) : (nil, nil)
        }
        XCTAssertEqual(snapshot, [current])
        XCTAssertThrowsError(try WriterAdmission.runningAppPortsProcesses(processIDs: [getpid(), other]) { pid in
            pid == getpid() ? (info, current.executablePath) : (nil, "/synthetic/AppPorts.app/Contents/MacOS/AppPorts")
        }, "An identified AppPorts writer still requires a readable identity")
    }

    func testCollectionRemovesDeadMalformedPresenceAndKeepsLivePresence() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let dead = admission.presenceURL(processID: 303)
        try Data("broken".utf8).write(to: dead)
        admission.pruneExitedPresences(timeBudget: 2, hasExited: { $0 == 303 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: admission.presenceURL(processID: 101).path))
        XCTAssertNoThrow(try admission.checkCurrentWriters())
    }

    func testCollectionRestoresConcurrentPublicationWithoutDeletingIt() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let record = admission.presenceURL(processID: 303)
        try Data("old".utf8).write(to: record)
        let replacement = Data("new registration".utf8)
        admission.pruneExitedPresences(timeBudget: 2, hasExited: { $0 == 303 }, beforeClaim: {
            try! replacement.write(to: record, options: .atomic)
        })
        XCTAssertEqual(try Data(contentsOf: record), replacement)
    }

    func testCollectionKeepsSymlinkAndItsTarget() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let target = fixture.directory.appendingPathComponent("protected")
        try Data("protected".utf8).write(to: target)
        let link = admission.presenceURL(processID: 303)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        admission.pruneExitedPresences(timeBudget: 2, hasExited: { $0 == 303 })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data("protected".utf8))
    }

    func testCollectionRespectsRemovalBudget() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        for pid in 303...312 { try Data("old".utf8).write(to: admission.presenceURL(processID: Int32(pid))) }
        admission.pruneExitedPresences(maximumRemoved: 2, timeBudget: 2, hasExited: { $0 >= 303 })
        let remaining = (303...312).filter { FileManager.default.fileExists(atPath: admission.presenceURL(processID: Int32($0)).path) }
        XCTAssertEqual(remaining.count, 8)
    }

    func testCollectionRestoresClaimWhenProcessAppearsBeforeDeletion() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let record = admission.presenceURL(processID: 303)
        let bytes = Data("preserve".utf8)
        try bytes.write(to: record)
        var exited = true
        admission.pruneExitedPresences(timeBudget: 2, hasExited: { $0 == 303 && exited }, beforeClaim: {
            exited = false
        })
        XCTAssertEqual(try Data(contentsOf: record), bytes)
    }

    func testCollectionRecoversInterruptedClaimWithoutOverwritingPublicRecord() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let claims = fixture.directory.appendingPathComponent(".writer-presence")
        let claim = claims.appendingPathComponent(".claim-303-" + UUID().uuidString)
        try Data("retained".utf8).write(to: claim)
        admission.pruneExitedPresences(timeBudget: 2, hasExited: { _ in false })
        let record = admission.presenceURL(processID: 303)
        XCTAssertEqual(try Data(contentsOf: record), Data("retained".utf8))
        try Data("older".utf8).write(to: claim)
        admission.pruneExitedPresences(timeBudget: 2, hasExited: { _ in false })
        XCTAssertEqual(try Data(contentsOf: record), Data("retained".utf8))
        XCTAssertEqual(try Data(contentsOf: claim), Data("older".utf8))
    }

    func testCollectionDoesNoWorkWithZeroScanBudget() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let record = admission.presenceURL(processID: 303)
        try Data("old".utf8).write(to: record)
        admission.pruneExitedPresences(maximumScanned: 0, hasExited: { _ in XCTFail("No inspection permitted"); return true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
    }

    func testBackgroundBatchesVisitTailAfterManyRetainedEntries() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        for pid in 303...602 {
            try Data("keep".utf8).write(to: admission.presenceURL(processID: Int32(pid)))
        }
        var visited = Set<Int32>()
        admission.pruneExitedPresences(maximumScanned: 8, timeBudget: 2,
                                      continueInBatches: true, hasExited: { pid in
            visited.insert(pid)
            return false
        })
        XCTAssertEqual(visited.count, 301)
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WriterAdmissionTests-" + UUID().uuidString)
        let current = WriterProcessIdentity(processID: 101, userID: getuid(), startSeconds: 1,
                                            startMicroseconds: 10, executablePath: "/synthetic/current/AppPorts")
        let other = WriterProcessIdentity(processID: 202, userID: getuid(), startSeconds: 2,
                                          startMicroseconds: 20, executablePath: "/synthetic/agent/AppPorts")
        var processes: [WriterProcessIdentity] = []

        init() { processes = [current] }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func admission(as process: WriterProcessIdentity? = nil) -> WriterAdmission {
            WriterAdmission(dataDirectory: directory, currentProcess: { process ?? self.current },
                            processSnapshot: { self.processes })
        }

        func write(_ presence: WriterPresence, using admission: WriterAdmission) throws {
            try DurableFileIO.write(try PropertyListEncoder().encode(presence),
                                    to: admission.presenceURL(processID: presence.process.processID))
        }
    }

    func testCompatibleMainAndDirectAgentInstancesCanShareTheDataset() throws {
        let fixture = Fixture()
        fixture.processes = [fixture.current, fixture.other]
        let main = fixture.admission()
        try main.registerCurrentProcess()
        XCTAssertThrowsError(try main.checkCurrentWriters())
        try fixture.admission(as: fixture.other).registerCurrentProcess()
        XCTAssertNoThrow(try main.checkCurrentWriters())
    }

    func testStartingAgentCanPublishItsPresenceBeforeAdmission() throws {
        let fixture = Fixture()
        fixture.processes.append(fixture.other)
        var now = 2.020020
        var waits = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes },
            clock: { now }, waitForRegistration: { interval in
                now += interval
                waits += 1
                if waits == 2 {
                    do { try fixture.admission(as: fixture.other).registerCurrentProcess() }
                    catch { XCTFail("Agent registration failed: \(error)") }
                }
            })
        try admission.registerCurrentProcess()
        XCTAssertNoThrow(try admission.checkCurrentWriters())
        XCTAssertEqual(waits, 2)
    }

    func testAgentExitingBetweenSnapshotAndPresenceReadDoesNotBlock() throws {
        let fixture = Fixture()
        var snapshots = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: {
                snapshots += 1
                return snapshots == 1 ? [fixture.current, fixture.other] : [fixture.current]
            }, waitForRegistration: { _ in XCTFail("An exited agent needs no startup wait") })
        try admission.registerCurrentProcess()
        XCTAssertNoThrow(try admission.checkCurrentWriters())
        XCTAssertGreaterThanOrEqual(snapshots, 3)
    }

    func testStartingUnregisteredWriterRemainsRejectedAfterBoundedWait() throws {
        let fixture = Fixture()
        fixture.processes.append(fixture.other)
        var now = 2.020020
        var waits = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes },
            clock: { now }, waitForRegistration: { interval in now += interval; waits += 1 })
        try admission.registerCurrentProcess()
        XCTAssertThrowsError(try admission.checkCurrentWriters())
        XCTAssertGreaterThan(waits, 0)
        XCTAssertLessThanOrEqual(waits, 40)
        XCTAssertLessThanOrEqual(now, 3.020020)
    }

    func testReusedPIDMustPublishTheNewIdentityBeforeAdmission() throws {
        let fixture = Fixture()
        let stale = WriterProcessIdentity(processID: fixture.other.processID, userID: getuid(),
            startSeconds: 1, startMicroseconds: 10, executablePath: fixture.other.executablePath)
        try fixture.admission(as: stale).registerCurrentProcess()
        fixture.processes.append(fixture.other)
        var now = 2.020020
        var waits = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes },
            clock: { now }, waitForRegistration: { interval in
                now += interval
                waits += 1
                do { try fixture.admission(as: fixture.other).registerCurrentProcess() }
                catch { XCTFail("New process registration failed: \(error)") }
            })
        try admission.registerCurrentProcess()
        XCTAssertNoThrow(try admission.checkCurrentWriters())
        XCTAssertEqual(waits, 1)
    }

    func testInstalledNewVersionDoesNotAuthorizeAnAlreadyRunningOldInstance() throws {
        let fixture = Fixture()
        let installed = fixture.directory.appendingPathComponent("Replaced.app")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.shimoko.AppPorts", "CFBundleVersion": "999"],
                                           format: .xml, options: 0).write(to: installed.appendingPathComponent("Contents/Info.plist"))
        let old = WriterProcessIdentity(processID: 202, userID: getuid(), startSeconds: 2, startMicroseconds: 20,
                                        executablePath: installed.appendingPathComponent("Contents/MacOS/AppPorts").path)
        fixture.processes = [fixture.current, old]
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        XCTAssertThrowsError(try admission.checkCurrentWriters()) { error in
            XCTAssertTrue(error.localizedDescription.contains("202"))
            XCTAssertTrue(error.localizedDescription.contains(old.executablePath))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Info.plist").path))
    }

    func testStalePresenceCannotAuthorizePIDReuseOrAnExecutableAtAnotherPath() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        try fixture.admission(as: fixture.other).registerCurrentProcess()
        let reused = WriterProcessIdentity(processID: fixture.other.processID, userID: getuid(), startSeconds: 3,
                                           startMicroseconds: 20, executablePath: fixture.other.executablePath)
        let differentExecutable = WriterProcessIdentity(processID: fixture.other.processID, userID: getuid(), startSeconds: 2,
                                                        startMicroseconds: 20, executablePath: "/synthetic/old/AppPorts")
        for process in [reused, differentExecutable] {
            fixture.processes = [fixture.current, process]
            XCTAssertThrowsError(try admission.checkCurrentWriters())
        }
        fixture.processes = [fixture.current]
        XCTAssertNoThrow(try admission.checkCurrentWriters(), "A dead instance's stale record is not a live writer")
    }

    func testRegistrationForAnotherDatasetCannotAuthorizeThisDataset() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let presence = WriterPresence(process: fixture.current, dataDirectoryPath: fixture.directory.appendingPathComponent("other").path,
                                      capabilities: [WriterAdmission.requiredCapability])
        try fixture.write(presence, using: admission)
        XCTAssertThrowsError(try admission.checkCurrentWriters())
    }

    func testMatchingProcessWithoutRequiredRuntimeCapabilityIsRejected() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let presence = WriterPresence(process: fixture.current,
                                      dataDirectoryPath: fixture.directory.resolvingSymlinksInPath().path,
                                      capabilities: ["old-writer"])
        try fixture.write(presence, using: admission)
        XCTAssertThrowsError(try admission.checkCurrentWriters())
    }

    func testMalformedOrLinkedPresenceDoesNotPermitWriting() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let record = admission.presenceURL(processID: fixture.current.processID)
        let saved = fixture.directory.appendingPathComponent("saved-presence.plist")
        try FileManager.default.copyItem(at: record, to: saved)
        try Data("not a property list".utf8).write(to: record)
        XCTAssertThrowsError(try admission.checkCurrentWriters())
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: saved)
        XCTAssertThrowsError(try admission.checkCurrentWriters())
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: record), "The rejected link target is preserved")
    }

    func testFailedOrIncompleteProcessInspectionFailsClosed() throws {
        let fixture = Fixture()
        let failed = WriterAdmission(dataDirectory: fixture.directory, currentProcess: { fixture.current },
                                     processSnapshot: { throw WriterAdmissionError.inspectionFailed(202, "unreadable") })
        try failed.registerCurrentProcess()
        XCTAssertThrowsError(try failed.checkCurrentWriters())
        fixture.processes = []
        XCTAssertThrowsError(try fixture.admission().checkCurrentWriters())
    }

    func testLateWriterIsRejectedAtTheNextOperationBoundaryWithoutReleasingTheOwnersLock() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let url = fixture.directory.appendingPathComponent("operation.lock")
        let owner = OperationLock(fileURL: url, writerAdmissionCheck: { try admission.checkCurrentWriters() })
        let observer = OperationLock(fileURL: url)
        defer { owner.release(); observer.release() }
        XCTAssertTrue(owner.tryAcquire())
        fixture.processes.append(fixture.other)
        XCTAssertThrowsError(try owner.recheckWriterAdmission())
        XCTAssertNotNil(owner.admissionFailureReason)
        XCTAssertFalse(observer.tryAcquire())
        fixture.processes.removeAll { $0 == fixture.other }
        XCTAssertNoThrow(try owner.recheckWriterAdmission())
        XCTAssertNil(owner.admissionFailureReason)
        owner.release()
        XCTAssertTrue(observer.tryAcquire())
    }

    func testWriterAppearingAfterFlockRejectsAndReleasesOnlyTheCandidateDescriptor() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        var checks = 0
        let url = fixture.directory.appendingPathComponent("operation.lock")
        let interrupted = OperationLock(fileURL: url, writerAdmissionCheck: {
            checks += 1
            if checks == 2 { fixture.processes.append(fixture.other) }
            try admission.checkCurrentWriters()
        })
        XCTAssertFalse(interrupted.tryAcquire())
        XCTAssertEqual(checks, 2)
        XCTAssertNotNil(interrupted.admissionFailureReason)
        let next = OperationLock(fileURL: url)
        defer { next.release() }
        XCTAssertTrue(next.tryAcquire(), "A failed post-lock admission check must release its candidate descriptor")
        interrupted.release()
        let observer = OperationLock(fileURL: url)
        XCTAssertFalse(observer.tryAcquire(), "A later rejected release cannot affect the successor")
    }

    func testRejectedAdmissionDoesNotWaitOrReleaseAnotherOperationsLock() async throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        fixture.processes.append(fixture.other)
        let url = fixture.directory.appendingPathComponent("operation.lock")
        let owner = OperationLock(fileURL: url)
        defer { owner.release() }
        XCTAssertTrue(owner.tryAcquire())
        let denied = OperationLock(fileURL: url, writerAdmissionCheck: { try admission.checkCurrentWriters() })
        let started = Date()
        let acquired = await denied.acquire(timeout: 30)
        XCTAssertFalse(acquired)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNotNil(denied.admissionFailureReason)
        denied.release()
        let observer = OperationLock(fileURL: url)
        XCTAssertFalse(observer.tryAcquire())
    }

    func testKernelProbeReadsCurrentProcessIdentityWithoutTouchingTheDefaultDataset() throws {
        let identity = try WriterAdmission.currentProcessIdentity()
        XCTAssertEqual(identity.processID, getpid())
        XCTAssertEqual(identity.userID, getuid())
        XCTAssertGreaterThan(identity.startSeconds, 0)
        XCTAssertTrue(identity.executablePath.hasPrefix("/"))
        XCTAssertTrue(try WriterAdmission.runningAppPortsProcesses().contains(identity))
    }

    func testKernelProbeDetectsADirectlyLaunchedUnregisteredExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WriterAdmissionProcess-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("AppPorts")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        // A copied platform binary can be killed by macOS before admission is
        // checked. Sign only this temporary fixture so it remains a live writer.
        let signature = try await ProcessCommandRunner().run(executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", executable.path], timeout: 15)
        XCTAssertEqual(signature.status, 0, signature.combinedText)
        guard signature.status == 0 else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let current = try WriterAdmission.currentProcessIdentity()
        var observed: WriterProcessIdentity?
        for _ in 0..<100 {
            observed = try WriterAdmission.runningAppPortsProcesses().first { $0.processID == process.processIdentifier }
            if observed != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let running = try XCTUnwrap(observed)
        XCTAssertEqual(running.executablePath, executable.resolvingSymlinksInPath().path)
        let admission = WriterAdmission(dataDirectory: directory.appendingPathComponent("isolated-data"),
            processSnapshot: { try WriterAdmission.runningAppPortsProcesses().filter { [current.processID, running.processID].contains($0.processID) } })
        try admission.registerCurrentProcess()
        XCTAssertTrue(process.isRunning, "The unregistered fixture must still be running when admission is checked")
        XCTAssertThrowsError(try admission.checkCurrentWriters()) { error in
            XCTAssertTrue(error.localizedDescription.contains(String(running.processID)))
        }
    }
}
