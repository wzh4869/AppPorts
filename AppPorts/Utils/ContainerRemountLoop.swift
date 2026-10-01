//
//  ContainerRemountLoop.swift
//  AppPorts
//

import Foundation

// MARK: - 重挂载重试循环

/// 自动挂载代理的重试策略：**只在真的发生事件时重试**，定时器只当兜底。
///
/// 为什么不是纯定时轮询：开机时系统很忙，外置盘可能过很久才被识别
/// （2026-09-23 那次是开机后 2 分 33 秒）。间隔太短会在开机最忙的时候空转 diskutil
/// （一次查询约 1 秒），间隔太长又会错过微信启动（登录后约 43 秒）。
/// 改成等 `/Volumes` 的真实事件后：盘一出现立刻重试，实测事件到挂载完成约 1 秒。
enum ContainerRemountLoop {

    struct Policy: Equatable, Sendable {
        /// 总等待窗口；用满就收工，剩下的交给下一次 `/Volumes` 变化或下次登录。
        var window: TimeInterval = 180
        /// 完全没有事件时的兜底复查间隔。只为兜住"事件丢了"这种意外，不是主要触发方式。
        var backstop: TimeInterval = 20
        /// 最多重试轮数（双保险，避免任何情况下死循环）。
        var maxCycles: Int = 20
    }

    /// 一轮尝试的结果。
    enum Attempt: Sendable {
        /// 让路：AppPorts 主应用正在做容器操作，这一轮没跑。保持原状态继续等。
        case deferred
        /// 跑完了，这是每条记录的状态。
        case results([ContainerVolumeMigrator.RemountOutcome])
    }

    enum StopReason: Equatable, Sendable {
        /// 所有记录都就位了。
        case settled
        /// 没有任何挂载记录。
        case noRecords
        /// 窗口用尽。
        case windowExpired
        /// 达到轮数上限。
        case cycleLimit
        /// 每一轮都在让路，一次都没跑成。
        case alwaysDeferred
    }

    struct Result: Sendable {
        let outcomes: [ContainerVolumeMigrator.RemountOutcome]
        let cycles: Int
        let deferredCycles: Int
        let reason: StopReason

        /// 是否真的等过（用来决定要不要在日志里交代等待过程）。
        var waited: Bool { cycles > 1 }
    }

    /// 还需要继续等的记录：卷没上线，或者这一轮挂载没成功。
    static func pendingRecords(
        in outcomes: [ContainerVolumeMigrator.RemountOutcome]
    ) -> [ContainerVolumeMigrator.RemountOutcome] {
        outcomes.filter {
            switch $0.state {
            case .mounted, .alreadyMounted, .requiresIntervention: return false
            case .unavailable, .failed: return true
            }
        }
    }

    /// 跑一轮重挂载；没就位就等事件，等到就再跑一轮。
    ///
    /// - Parameters:
    ///   - attempt: 一轮尝试（拿锁 → 重挂载 → 放锁）。锁只在单轮里持有，等待期间不占锁，
    ///     用户此刻在 AppPorts 里的操作不会被卡住。
    ///   - waitForChange: 等下一次目录变化的秒数（返回 nil 表示超时）；定时器只做兜底。
    ///   - now: 时间源，测试时注入。
    static func run(
        policy: Policy = Policy(),
        attempt: () async -> Attempt,
        waitForChange: (TimeInterval) async -> VolumeChangeMonitor.Change?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> Result {
        let deadline = now().addingTimeInterval(policy.window)
        var outcomes: [ContainerVolumeMigrator.RemountOutcome] = []
        var cycles = 0
        var deferredCycles = 0
        var sawResults = false
        var waitingLogged = false
        var stopReason: StopReason?

        while cycles < policy.maxCycles {
            cycles += 1
            switch await attempt() {
            case .deferred:
                deferredCycles += 1
            case .results(let latest):
                sawResults = true
                outcomes = latest
                if latest.isEmpty {
                    return Result(outcomes: latest, cycles: cycles, deferredCycles: deferredCycles, reason: .noRecords)
                }
                let pending = pendingRecords(in: latest)
                if pending.isEmpty {
                    return Result(outcomes: latest, cycles: cycles, deferredCycles: deferredCycles, reason: .settled)
                }
                if !waitingLogged {
                    waitingLogged = true
                    AppLogger.shared.logContext(
                        "还有挂载点没就位，开始等外置卷出现",
                        details: [
                            ("pending", String(pending.count)),
                            ("window_seconds", Self.seconds(policy.window)),
                            ("backstop_seconds", Self.seconds(policy.backstop))
                        ]
                    )
                    for outcome in pending {
                        AppLogger.shared.logContext(
                            "等待中的挂载点",
                            details: [
                                ("mount_point", outcome.record.mountPointPath),
                                ("volume", outcome.record.volumeName),
                                ("state", String(describing: outcome.state))
                            ],
                            level: "TRACE"
                        )
                    }
                }
            }

            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else {
                stopReason = .windowExpired
                break
            }
            let timeout = min(remaining, policy.backstop)
            if let change = await waitForChange(timeout) {
                AppLogger.shared.logContext(
                    "等到目录变化，重试挂载",
                    details: [
                        ("cycle", String(cycles)),
                        ("waited_seconds", String(format: "%.1f", change.waited)),
                        ("flags", change.flagsDescription)
                    ]
                )
            } else if remaining > policy.backstop {
                AppLogger.shared.logContext(
                    "等待窗口内没有目录变化，兜底复查一次",
                    details: [("cycle", String(cycles)), ("timeout_seconds", Self.seconds(timeout))],
                    level: "TRACE"
                )
            }
        }

        // 一次都没跑成（一直在给主应用让路）时如实说明，别让日志看起来像"没有记录"。
        let reason: StopReason = (!sawResults && deferredCycles > 0) ? .alwaysDeferred : (stopReason ?? .cycleLimit)
        return Result(outcomes: outcomes, cycles: cycles, deferredCycles: deferredCycles, reason: reason)
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(Int(interval.rounded()))
    }
}
