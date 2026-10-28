import XCTest
import Darwin
@testable import AppPorts

/// 跨进程锁：让登录代理和主应用不要同时抢同一个挂载点。
///
/// 用两个「各自 open 一遍锁文件」的实例来测：`flock` 的锁跟着打开的文件描述走，
/// 所以同一个进程里另开一个 fd 也能复现冲突，不需要真的起第二个进程。
final class OperationLockTests: XCTestCase {

    private func makeLockFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationLockTests-\(UUID().uuidString)")
            .appendingPathComponent("operation.lock")
    }

    func testDiagnosticDistinguishesLockScopesWithoutClaimingAnOwner() throws {
        let url = makeLockFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let owner = OperationLock(fileURL: url, writerAdmissionCheck: {})
        let waiter = OperationLock(fileURL: url, writerAdmissionCheck: {})
        XCTAssertTrue(owner.tryAcquire())
        defer { owner.release() }
        XCTAssertFalse(waiter.tryAcquire())
        let global = waiter.diagnosticFailure(scope: .global)
        let signature = waiter.diagnosticFailure(scope: .signature)
        XCTAssertEqual(global.reason, .globalLockBusy)
        XCTAssertEqual(signature.reason, .signatureLockBusy)
        XCTAssertEqual(global.diagnosticFields["lock_owner"], "unknown")
        XCTAssertNil(global.blockingOperationID)
        let underlying = try XCTUnwrap((global as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
        XCTAssertEqual(underlying.code, Int(EWOULDBLOCK))
        owner.release()
        XCTAssertTrue(waiter.tryAcquire())
        XCTAssertNil(waiter.diagnosticFailure(scope: .global).systemErrorCode, "Successful acquire clears the prior failure facts")
        waiter.release()
    }

    func testInaccessibleLockIsNotReportedAsBusy() throws {
        let url = makeLockFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let lock = OperationLock(fileURL: url, writerAdmissionCheck: {})
        XCTAssertFalse(lock.tryAcquire())
        let failure = lock.diagnosticFailure(scope: .global)
        XCTAssertEqual(failure.reason, .lockUnavailable)
        XCTAssertEqual(failure.systemErrorCode, EISDIR)
        XCTAssertEqual(failure.lockURL, url)
    }

    func testSymlinkLockFailureDoesNotFollowOrModifyItsTarget() throws {
        let url = makeLockFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = url.deletingLastPathComponent().appendingPathComponent("target")
        let bytes = Data("sentinel".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let lock = OperationLock(fileURL: url, writerAdmissionCheck: {})
        XCTAssertFalse(lock.tryAcquire())
        let failure = lock.diagnosticFailure(scope: .signature)
        XCTAssertEqual(failure.reason, .lockUnavailable)
        XCTAssertEqual(failure.systemErrorCode, ELOOP)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testManagedLeaseDiagnosticPreservesFailureAndClearsItAfterAcquire() throws {
        let url = makeLockFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let owner = OperationLock(fileURL: url, writerAdmissionCheck: {})
        let waiter = OperationLock(fileURL: url, writerAdmissionCheck: {})
        XCTAssertTrue(owner.tryAcquire())
        defer { owner.release() }
        MigrationExecution.$managed.withValue(true) {
            XCTAssertFalse(waiter.tryAcquire())
        }
        XCTAssertEqual(waiter.diagnosticFailure(scope: .global).reason, .globalLockBusy)
        owner.release()
        MigrationExecution.$managed.withValue(true) {
            XCTAssertTrue(waiter.tryAcquire())
        }
        XCTAssertNil(waiter.diagnosticFailure(scope: .global).systemErrorCode)
        waiter.release()
    }

    func testAdmissionFailurePreservesItsUnderlyingError() throws {
        let url = makeLockFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = NSError(domain: "SyntheticAdmission", code: 42, userInfo: [NSLocalizedDescriptionKey: "Synthetic blocked writer"])
        let lock = OperationLock(fileURL: url, writerAdmissionCheck: { throw original })
        XCTAssertFalse(lock.tryAcquire())
        let failure = lock.diagnosticFailure(scope: .global)
        XCTAssertEqual(failure.reason, .writerAdmission)
        XCTAssertEqual(failure.admissionReason, original.localizedDescription)
        XCTAssertEqual(failure.underlyingError?.domain, original.domain)
        XCTAssertEqual(failure.underlyingError?.code, original.code)
    }

    func testManagedLeaseRemainsExclusiveUntilEveryNestedHolderFinishes() {
        let url = makeLockFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = OperationLock(fileURL: url)
        let nested = OperationLock(fileURL: url)
        let outsider = OperationLock(fileURL: url)
        MigrationExecution.$managed.withValue(true) {
            XCTAssertTrue(first.tryAcquire())
            XCTAssertTrue(nested.tryAcquire())
        }
        XCTAssertFalse(outsider.tryAcquire())
        first.release()
        XCTAssertFalse(outsider.tryAcquire())
        nested.release()
        XCTAssertTrue(outsider.tryAcquire())
        outsider.release()
    }

    func testSecondHolderCannotAcquireWhileTheFirstHoldsTheLock() {
        let url = makeLockFileURL()
        let first = OperationLock(fileURL: url)
        let second = OperationLock(fileURL: url)

        XCTAssertTrue(first.tryAcquire())
        XCTAssertFalse(second.tryAcquire(), "第一个持有者还没释放，第二个不该拿到锁")
        XCTAssertTrue(second.isHeldByAnotherProcess, "代理靠这个判断要不要让路")

        first.release()
        XCTAssertFalse(second.isHeldByAnotherProcess)
        XCTAssertTrue(second.tryAcquire(), "释放后应该能拿到")
        second.release()
    }

    func testReleaseOnANonHolderIsHarmless() {
        let url = makeLockFileURL()
        let first = OperationLock(fileURL: url)
        let second = OperationLock(fileURL: url)

        second.release() // 没持锁，什么都不该做
        XCTAssertTrue(first.tryAcquire())
        second.release() // 也不该把别人的锁放掉
        XCTAssertFalse(second.tryAcquire(), "被别人的 release 影响，说明锁被误放了")
        first.release()
    }

    func testAcquireGivesUpAfterTimeout() async {
        let url = makeLockFileURL()
        let holder = OperationLock(fileURL: url)
        let waiter = OperationLock(fileURL: url)

        XCTAssertTrue(holder.tryAcquire())
        let acquired = await waiter.acquire(timeout: 0.3)
        XCTAssertFalse(acquired, "别的进程一直持锁时应该超时返回 false，而不是干等")

        holder.release()
        let acquiredAfterRelease = await waiter.acquire(timeout: 0.3)
        XCTAssertTrue(acquiredAfterRelease)
        waiter.release()
    }

    func testAcquiringTwiceIsIdempotentForTheSameInstance() {
        let url = makeLockFileURL()
        let lock = OperationLock(fileURL: url)
        let observer = OperationLock(fileURL: url)

        XCTAssertTrue(lock.tryAcquire())
        XCTAssertTrue(lock.tryAcquire(), "同一实例重复拿锁返回 true，但不能重复计数")
        lock.release()
        XCTAssertTrue(observer.tryAcquire(), "一次 release 就要彻底放开")
        observer.release()
    }

    func testConcurrentOperationsHaveOnlyOneLockOwner() async {
        let url = makeLockFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let operationCount = 8
        let attempts = LockAttemptBarrier(participantCount: operationCount)

        let acquisitions = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<operationCount {
                group.addTask {
                    let operationLock = OperationLock(fileURL: url)
                    defer { operationLock.release() }
                    let acquired = await operationLock.acquire(timeout: 0)
                    // 持有者必须等其它任务都试过，避免释放后另一个任务合法接棒。
                    await attempts.arriveAndWait()
                    return acquired
                }
            }
            var results: [Bool] = []
            for await acquired in group { results.append(acquired) }
            return results
        }

        XCTAssertEqual(acquisitions.filter { $0 }.count, 1, "并发操作不能共享同一实例的幂等 acquire")
        let nextOperation = OperationLock(fileURL: url)
        defer { nextOperation.release() }
        XCTAssertTrue(nextOperation.tryAcquire(), "全部操作结束后应能重新获得锁")
    }

    func testFailedConcurrentOperationsCannotReleaseAnotherOperationsLock() async {
        let url = makeLockFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let owner = OperationLock(fileURL: url)
        defer { owner.release() }
        guard owner.tryAcquire() else {
            XCTFail("无法建立测试持有者")
            return
        }

        let acquisitions = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let rejectedOperation = OperationLock(fileURL: url)
                    // 模拟失败路径的清理：只能释放自身持有的描述符。
                    defer { rejectedOperation.release() }
                    return await rejectedOperation.acquire(timeout: 0)
                }
            }
            var results: [Bool] = []
            for await acquired in group { results.append(acquired) }
            return results
        }

        XCTAssertFalse(acquisitions.contains(true))
        let successor = OperationLock(fileURL: url)
        defer { successor.release() }
        XCTAssertFalse(successor.tryAcquire(), "失败操作的 defer 不能放掉仍在执行的操作的锁")

        owner.release()
        XCTAssertTrue(successor.tryAcquire())
        owner.release()
        let observer = OperationLock(fileURL: url)
        defer { observer.release() }
        XCTAssertFalse(observer.tryAcquire(), "旧持有者迟到的 release 不能释放接棒者的锁")
        successor.release()
        XCTAssertTrue(observer.tryAcquire())
    }

    // MARK: - 调用点审计

    /// 调用点静态接线检查；互斥行为由上面的真实锁测试覆盖。
    /// 这不证明任意控制流下都不能绕过锁。
    func testContainerMountCallSitesRetainLockAdmissionSourceWiring() throws {
        let root = try repositoryRootURL()

        let agentSource = try String(
            contentsOf: root.appendingPathComponent("AppPorts/Services/ContainerMountAgentInstaller.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            agentSource.contains("await lock.acquire(timeout:"),
            "代理没有在动手前等主应用让出锁"
        )
        XCTAssertTrue(
            agentSource.contains("OperationLock.agentWaitTimeout"),
            "代理第一轮应该等满主应用的让路时长，而不是匆匆跳过"
        )
        XCTAssertTrue(
            agentSource.contains("自动挂载代理让路"),
            "代理拿不到锁时应该让路并记日志"
        )
        let acquireOffset = agentSource.range(of: "await lock.acquire(timeout:").map {
            agentSource.distance(from: agentSource.startIndex, to: $0.lowerBound)
        }
        let remountOffset = agentSource.range(of: "await migrator.remountAvailableRecords()").map {
            agentSource.distance(from: agentSource.startIndex, to: $0.lowerBound)
        }
        if let acquireOffset, let remountOffset {
            XCTAssertLessThan(acquireOffset, remountOffset, "挂载动作必须发生在拿到锁之后")
        } else {
            XCTFail("没有找到代理拿锁或挂载的调用点，审计失效")
        }

        let dataDirsViewSource = try String(
            contentsOf: root.appendingPathComponent("AppPorts/Views/DataDirsView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(dataDirsViewSource.contains("OperationLock.shared"))
        XCTAssertFalse(agentSource.contains("OperationLock.shared"))
        let operations = ["migrateAndComplete", "restoreAndComplete", "normalizeManagedLinkAndComplete",
                          "createLink", "mount", "unmount", "resumeVerifiedTransfer", "cancelUnstartedRestore",
                          "cancelUnstartedMigration", "cancelPreparation", "cleanupRetainedTransfer", "retryCleanup", "discardCleanupRecord"]
        var audited = 0
        for function in dataDirsViewSource.components(separatedBy: "\n    private func ").dropFirst() {
            guard let mutation = operations.compactMap({ function.range(of: ".\($0)(") })
                .min(by: { $0.lowerBound < $1.lowerBound }) else { continue }
            let name = String(function.prefix { $0 != "(" })
            let submission = try XCTUnwrap(function.range(of: "submitDataTask("), "\(name) must use the locked scheduler")
            XCTAssertLessThan(submission.lowerBound, mutation.lowerBound)
            audited += 1
        }
        XCTAssertGreaterThanOrEqual(audited, 8)
        XCTAssertTrue(dataDirsViewSource.contains("MigrationTaskCenter.shared.submit("))
        XCTAssertTrue(dataDirsViewSource.contains("resources: MigrationResources(paths: paths, keys: keys)"))
        let scheduler = try String(contentsOf: root.appendingPathComponent("AppPorts/Services/MigrationTaskCenter.swift"), encoding: .utf8)
        let acquire = try XCTUnwrap(scheduler.range(of: "guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else"))
        let execution = try XCTUnwrap(scheduler.range(of: "return try await operation(progress)"))
        XCTAssertLessThan(acquire.lowerBound, execution.lowerBound)
        let beforeExecution = scheduler[acquire.upperBound..<execution.lowerBound]
        XCTAssertTrue(beforeExecution.contains("throw lock.diagnosticFailure(scope: .global)"))
        XCTAssertTrue(beforeExecution.contains("defer { lock.release() }"))
        XCTAssertTrue(scheduler.contains("MigrationExecution.$managed.withValue(true)"))

        let contentViewSource = try String(
            contentsOf: root.appendingPathComponent("AppPorts/ContentView.swift"),
            encoding: .utf8
        )
        XCTAssertNotNil(contentViewSource.range(of: #"await\s+OperationMaintenance\.shared\.run\s*\("#, options: .regularExpression))
        XCTAssertFalse(contentViewSource.contains("OperationLock.shared"))
        let maintenanceSource = try String(
            contentsOf: root.appendingPathComponent("AppPorts/Services/OperationMaintenance.swift"),
            encoding: .utf8
        )
        let maintenanceStart = try XCTUnwrap(maintenanceSource.range(
            of: #"private\s+static\s+func\s+finishDataOperations\s*\("#, options: .regularExpression))
        let maintenance = String(maintenanceSource[maintenanceStart.upperBound...])
        XCTAssertTrue(maintenance.contains("let lock = OperationLock()"))
        XCTAssertTrue(maintenance.contains("guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else"))
        XCTAssertTrue(maintenance.contains("defer { lock.release() }"))
        XCTAssertFalse(maintenance.contains("OperationLock.shared"))
        let lockGuard = try XCTUnwrap(maintenance.range(of: "guard await lock.acquire("))
        for mutation in ["await migrator.performAutomaticMaintenance(ignoresRetryBackoff: interactive)", "await migrator.remountAvailableRecords()",
                         "await DataDirMover().resumeVerifiedTransfer("] {
            let operation = try XCTUnwrap(maintenance.range(of: mutation))
            XCTAssertLessThan(lockGuard.lowerBound, operation.lowerBound)
            XCTAssertTrue(maintenance[lockGuard.upperBound..<operation.lowerBound].contains("return ["),
                          "Maintenance must stop when another process owns the operation lock")
        }
    }

    private func repositoryRootURL() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor LockAttemptBarrier {
    private let participantCount: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == participantCount {
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
