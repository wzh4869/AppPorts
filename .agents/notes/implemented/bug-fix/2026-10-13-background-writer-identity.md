# Agent Note: 后台写入者准入绑定实际进程与代理签名

Status: implemented

> 迁移自 docs/apfs-wechat-validation-2026-10-13.md
> 迁移自 docs/apfs-cross-app-validation-2026-10-14.md

## Problem

无关不可读进程被视为潜在 AppPorts 会误阻塞迁移；新代理出现在进程表时尚未完成能力登记，也可能被错误拒绝。另一方向上，原路径替换二进制后 launchd 仍保留旧签名约束，会导致文件验签通过但代理无法启动。

## Decision

`WriterAdmission` 先确定进程确实关联 AppPorts，再检查它的身份与能力。对于刚启动、登记尚未完成的相关代理，只短暂等待并重新核对 PID、启动时间和能力；不能仅凭路径放行。相关但无法证实兼容的进程继续阻止并发破坏性写入。

代理定义包含当前 executable CDHash。签名变化时重新注册；定义未变但服务不存在时补注册。进程准入、launchd 注册与持久化格式保护分别负责自己的范围，schema 号不能阻止不理解它的旧应用服务。

## Existing evidence

2026-10-13 来源把隔离测试宿主崩溃与生产 `Launch Constraint Violation` 分开定位；生产代理有独立运行记录。10 月 14 日记录短暂登记竞态和 build 30 的 CDHash/注册一致、退出码 0。

## Related decisions

- 退出后的登记垃圾回收见[已退出进程登记的有界回收](2026-10-28-writer-presence-collection.md)；回收不能代替运行进程的身份准入。

- 进程准入与持久化格式共同约束写入，见[迁移以持久化切换和可重试清理为完成依据](../../implemented/architecture/2026-10-10-verified-transfer-lifecycle.md)。
- 代理登记与代理在未完成恢复期间的生命周期相关，见[由持久化事务自动完成 APFS 恢复与清理](../architecture/2026-10-12-apfs-automatic-recovery.md)。


[主动弹出外盘](../feature/2026-10-23-explicit-disk-ejection.md)把 required capability 提升到 `appports-verified-writer-v7-disk-ejection`，确保旧写入进程不能忽略新暂停文件。

## Alternatives considered

- **拒绝同 UID 的全部不可读进程**：保守但把无关程序变成全局操作障碍。
- **刚启动代理按路径直接放行**：省去等待，却无法证明启动身份和写入能力，PID 复用也可能误认。
- **二进制仍在原路径就复用注册**：减少 launchd 操作，但旧启动约束可能已不匹配新签名。

## Consequences

无关不可读进程不阻断，相关未知或不兼容 writer 仍被拒绝；代理登记延迟可经有界等待恢复，进程身份变化不能继承准入。更新二进制和缺失服务均正确注册，记录与真实运行签名一致。

代价与边界：登记等待必须有界，不能放宽对未确认 writer 的限制；新版退出后无法阻止用户主动运行旧版，真实重启/登录竞态与其他系统仍未由来源覆盖。build 28 的组合测试曾失败，后续独立 23 项通过不能把前轮改写成全部通过。
