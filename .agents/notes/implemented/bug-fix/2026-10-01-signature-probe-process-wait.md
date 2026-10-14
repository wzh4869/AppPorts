# Agent Note: 签名探测在启动线程等待并独立计时

Status: implemented

> 迁移自合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/实施验收/implementation/signature-wait-report.md（S039）

## Problem

AppScanner 的真实签名探测间歇性卡到 10 秒并返回无法确定，实际子进程早已退出。旧 helper 将 waitUntilExit 放到另一队列，启动线程等待信号量；异步任务调用下无法可靠观察完成，增加期限只会延长误报。

## Decision

`Process.waitUntilExit(withTimeout:)` 在启动线程调用 Foundation 等待，独立计时器负责期限。期限状态受锁保护，正常完成取消计时器；真正超时只终止本 helper 启动的子进程，100 ms 后仍未结束时用 SIGKILL 后备，并等待回收再返回。

签名探测仍保留 10 秒期限和原 codesign 参数及分类。超时返回无法确定，不冒充未签名、有效或无沙盒；helper 已回收子进程后不再第二次 terminate。签名备份与显式恢复逻辑不承担等待器修复。

## Related decisions

- 此处是 AppScanner 的等待器；磁盘命令输出与继承管道的完成条件见[进程退出不能等待低优先级管道读取](2026-09-29-nonblocking-process-completion.md)。

## Alternatives considered

- **跨线程 waitUntilExit 加启动线程信号量**：可把阻塞移到全局队列，但短 sleep 与真实签名夹具都复现退出已完成却超时，不能作为可靠完成信号。

原文档未记录第二个独立候选方案，不把增加超时或伪造探测结果写成当时已评估的方案。

## Consequences

正常短进程退出与真正超时有独立证据，忽略 SIGTERM 的子进程也有有界终止和回收路径。代价是计时状态同步与子进程生命周期必须一致；该修复不能证明所有 Foundation Process 使用路径没有其他问题。

## Verification

原独立 sleep 探针在异步启动中有 19/40 次误超时，失败时 kill(pid, 0) 返回 ESRCH；匹配生产调用的逐次 detached task 回归有 25/30 次误超时。修复后来源记录 21 项相关测试通过，包括 30 次短子进程、退出码 0/23、忽略 SIGTERM 的超时回收及 12 次真实 codesign 探测。核对 `AppScannerProcessWaitTests`、`AppScannerSignatureCheckTests`；此次不重签或操作真实应用。
