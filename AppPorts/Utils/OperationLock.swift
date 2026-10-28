//
//  OperationLock.swift
//  AppPorts
//

import Darwin
import Foundation

/// 跨进程互斥锁：让「登录代理」和「AppPorts 主应用」不要同时去动同一批挂载点。
///
/// 登录代理监听 `/Volumes`（见 `ContainerMountAgentInstaller.launchAgentPayload`），
/// 外置卷一有变化它就会立刻跑一遍；而 AppPorts 自己做挂载迁移、挂载、卸载、还原时
/// 也会挂载和卸载卷 —— 于是就有了「用户正在 AppPorts 里还原，代理同时插进来抢同一个
/// 挂载点」的竞态。
///
/// 代理是独立进程，看不到主应用内存里的 `AppOperationState`，所以这里用文件锁跨进程协调：
/// 同一时刻只有一个进程能持有 `~/Library/Application Support/AppPorts/operation.lock`。
/// 用 `flock` 而不是「写一个锁文件、用完删掉」：进程崩了内核会自动释放，不会留下死锁。
///
/// 约定：锁只在最外层操作拿一次、由拿到的那一层释放。不要在已经持锁时再 `tryAcquire`
/// —— 同一个实例会直接返回 `true`，多出来的那次 `release()` 会把外层的锁一起放掉。
final class OperationLock: @unchecked Sendable {
    static let shared = OperationLock()

    /// 代理等待主应用让出锁的时长；超过就跳过本次运行，等下一次卷变化或下次登录。
    static let agentWaitTimeout: TimeInterval = 120

    /// 主应用等待代理跑完的时长；代理单次运行实测约 4 秒。
    static let appWaitTimeout: TimeInterval = 15

    static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts/operation.lock")
    }

    private let fileURL: URL
    private let writerAdmissionCheck: () throws -> Void
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var managedLease = false
    private var lastAdmissionFailure: String?
    private enum AcquisitionFailure { case busy(Int32), unavailable(Int32), admission(Error) }
    private var lastAcquisitionFailure: AcquisitionFailure?

    enum DiagnosticScope: Equatable { case global, signature }

    /// Snapshot the actual acquisition failure; never infer who owns the lock.
    func diagnosticFailure(scope: DiagnosticScope, applicationURL: URL? = nil) -> OperationBlockage {
        stateLock.lock(); defer { stateLock.unlock() }
        let reason: OperationBlockage.Reason
        var code: Int32?
        var admission: String?
        var underlying: NSError?
        switch lastAcquisitionFailure {
        case .busy(let value): reason = scope == .global ? .globalLockBusy : .signatureLockBusy; code = value
        case .unavailable(let value): reason = .lockUnavailable; code = value
        case .admission(let value): reason = .writerAdmission; admission = value.localizedDescription; underlying = value as NSError
        case nil: reason = .lockUnavailable
        }
        return OperationBlockage(reason: reason, applicationURL: applicationURL, lockURL: fileURL,
                                 systemErrorCode: code, admissionReason: admission, underlyingError: underlying)
    }

    init(fileURL: URL = OperationLock.defaultFileURL, writerAdmissionCheck: (() throws -> Void)? = nil) {
        self.fileURL = fileURL
        self.writerAdmissionCheck = writerAdmissionCheck ?? {
            try WriterAdmission.prepareForWrite(dataDirectory: fileURL.deletingLastPathComponent())
        }
    }

    deinit { release() }

    /// Distinguishes a live incompatible writer from ordinary lock contention.
    var admissionFailureReason: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastAdmissionFailure
    }

    func recheckWriterAdmission() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        do {
            try writerAdmissionCheck()
            lastAdmissionFailure = nil
        } catch {
            lastAdmissionFailure = error.localizedDescription
            throw error
        }
    }

    /// 当前是否被**别的进程**持有。只探测、不拿锁，用来记日志判断谁在让路。
    var isHeldByAnotherProcess: Bool {
        stateLock.lock()
        let alreadyHeldBySelf = descriptor >= 0 || managedLease
        stateLock.unlock()
        guard !alreadyHeldBySelf else { return false }

        guard let probe = openDescriptor(recordFailure: false) else { return false }
        defer {
            _ = flock(probe, LOCK_UN)
            _ = close(probe)
        }
        // flock 的锁跟着「打开的文件描述」走，所以同一个进程里另开一个 fd 也能探到冲突。
        return flock(probe, LOCK_EX | LOCK_NB) != 0
    }

    /// 试一次，不等待。已经在持锁状态时返回 `true`（不会重复计数）。
    @discardableResult
    func tryAcquire() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        lastAcquisitionFailure = nil
        guard checkAdmission() else { return false }
        if descriptor >= 0 || managedLease { return true }

        if MigrationExecution.managed {
            managedLease = ManagedOperationLeases.shared.acquire(path: fileURL.standardizedFileURL.path) {
                guard let candidate = self.openDescriptor() else { return nil }
                guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
                    self.recordFlockFailure(errno)
                    _ = close(candidate)
                    return nil
                }
                guard self.checkAdmission() else {
                    _ = close(candidate)
                    return nil
                }
                return candidate
            }
            return managedLease
        }

        guard let candidate = openDescriptor() else { return false }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            recordFlockFailure(errno)
            _ = close(candidate)
            return false
        }
        // An older main app or directly launched agent can appear while this
        // operation waits for the file lock; inspect the live process list again.
        guard checkAdmission() else {
            _ = flock(candidate, LOCK_UN)
            _ = close(candidate)
            return false
        }
        descriptor = candidate
        return true
    }

    /// 最多等 `timeout` 秒。拿不到返回 `false`，由调用方决定跳过还是照常执行。
    func acquire(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if tryAcquire() { return true }
            if admissionFailureReason != nil || Task.isCancelled { return false }
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 释放锁。没持锁时什么都不做。
    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if managedLease {
            ManagedOperationLeases.shared.release(path: fileURL.standardizedFileURL.path)
            managedLease = false
            return
        }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    // MARK: - 私有辅助

    /// Only called while stateLock is held. A rejected attempt never owns or
    /// releases another OperationLock instance's descriptor.
    private func checkAdmission() -> Bool {
        do {
            try writerAdmissionCheck()
            lastAdmissionFailure = nil
            return true
        } catch {
            lastAdmissionFailure = error.localizedDescription
            lastAcquisitionFailure = .admission(error)
            return false
        }
    }

    private func recordFlockFailure(_ code: Int32) {
        lastAcquisitionFailure = code == EWOULDBLOCK || code == EAGAIN ? .busy(code) : .unavailable(code)
    }

    private func openDescriptor(recordFailure: Bool = true) -> Int32? {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let candidate = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard candidate >= 0 else {
            let code = errno
            if recordFailure { lastAcquisitionFailure = .unavailable(code) }
            return nil
        }
        var info = stat()
        let result = fstat(candidate, &info)
        let code = result == 0 ? EINVAL : errno
        guard result == 0, info.st_mode & S_IFMT == S_IFREG else {
            if recordFailure { lastAcquisitionFailure = .unavailable(code) }
            _ = close(candidate)
            return nil
        }
        return candidate
    }
}

/// The scheduler owns path reservations before this pool is used. Sharing is
/// opt-in for managed jobs only: all other local writers and external agents
/// still contend on the same exclusive flock until the final job releases it.
private final class ManagedOperationLeases: @unchecked Sendable {
    static let shared = ManagedOperationLeases()
    private let lock = NSLock()
    private struct Lease { let descriptor: Int32; var owners: Int }
    private var leases: [String: Lease] = [:]

    func acquire(path: String, open: () -> Int32?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if var lease = leases[path] {
            lease.owners += 1
            leases[path] = lease
            return true
        }
        guard let descriptor = open() else { return false }
        leases[path] = Lease(descriptor: descriptor, owners: 1)
        return true
    }

    func release(path: String) {
        lock.lock(); defer { lock.unlock() }
        guard var lease = leases[path] else { return }
        lease.owners -= 1
        if lease.owners == 0 {
            _ = flock(lease.descriptor, LOCK_UN)
            _ = close(lease.descriptor)
            leases.removeValue(forKey: path)
        } else { leases[path] = lease }
    }
}
