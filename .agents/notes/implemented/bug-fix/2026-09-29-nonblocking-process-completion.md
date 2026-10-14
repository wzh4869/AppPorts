# Agent Note: 进程退出不能等待低优先级管道读取

Status: implemented

> 迁移自 docs/validation/process-command-runner.md

## Problem

Foundation 的高优先级 terminationHandler 若通过 DispatchGroup.wait 等待 Utility 输出读取，会产生优先级反转。子进程退出也不代表继承管道的后代已关闭输出，过早返回会截断结果，无限等待则破坏超时语义。

## Decision

`ProcessCommandRunner` 在 Utility worker 中执行有界的非阻塞管道读取，以统一 deadline 管理排队、启动、子进程与继承管道。Foundation 的退出回调队列不承担等待输出排空的工作。结果在对应完成条件满足时恢复异步调用，命令间的 stdout/stderr 保持隔离。

早期修复用 DispatchGroup.notify 实现“不阻塞退出回调”的同一决定；当前源码采用非阻塞读取循环，不能继续把 notify 写成现行机制。后台 QoS 和性能检查器不是掩盖阻塞的调节按钮。

期限从调用进入计时，包含排队与启动；已过期或已取消的任务不能再启动子进程。设置非阻塞管道必须检查 fcntl 返回结果，否则读取循环仍可能阻塞并绕过 deadline。

10 月 5 日全量验收曾有两个超时参数场景耗时约 2 秒，单套件与诊断并发重跑未复现原始延迟，来源未确认其根因。实际确认并修复的是排队/启动未计时和非阻塞设置未检查；16 路并发、取消和过期不启动回归保留原 1.5 秒阈值，没有靠放宽阈值算通过。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/P/提交报告.md（S066）。

## Related decisions

- 另一个已退出进程被误判超时的机制见[签名探测在启动线程等待并独立计时](2026-10-01-signature-probe-process-wait.md)，不能把两个 Process 修复混为同一根因。

- 命令期限不能被扩大为整个数据恢复的固定总预算，见[由持久化事务自动完成 APFS 恢复与清理](../../proposed/architecture/2026-10-12-apfs-automatic-recovery.md)。

## Alternatives considered

- **terminationHandler 内同步等待两路读取**：退出与输出汇合简单，但高优先级回调被低优先级任务阻塞，来源有系统检查器复现。
- **提高所有输出读取任务优先级或关闭检查器**：可能减少告警，却不消除阻塞依赖与继承管道的等待问题；来源明确未采用。

## Consequences

命令输出完整性与超时可以在 worker 中统一处理，避免在系统退出回调中制造反转。代价是需要处理非阻塞读取、取消、子进程终止和后代持有管道的边界；本篇不声称所有线程路径已被穷尽验证。

## Verification

`AppPorts/Utils/DiskUtility.swift` 的 `ProcessCommandRunner` 与 `AppPortsTests/ProcessCommandRunnerTests.swift` 是当前核对入口。2026-09-29 来源记录修复前后同样 128 条命令的检查器对照、完整双路输出及后续全量回归。该历史实测不代表当前执行器全部后续修改都在同一轮测过；当前边界以现有回归为准。
