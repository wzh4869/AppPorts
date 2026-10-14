# Agent Note: 旧容器重连保持原有所有权语义

Status: implemented

> 迁移自 docs/superpowers/plans/2026-10-07-legacy-remount.md

## Problem

历史容器卷缺少 ownershipPolicy，普通重连若要求它们满足新版严格所有权条件，会阻断原本可用的数据。未开始的还原也可能通过自己的路径预留阻挡正常重挂。

## Decision

重挂对缺少严格所有权证据的旧记录明确选择 `noowners`；已有 ownershipPolicy 或相应验证依据的记录保持其严格要求。该兼容分流不改变整个外盘的所有权设置，也不在观察阶段扰动已经挂载的旧卷。

未开始的还原只有在原卷身份、生成路径和事务一致，且没有 staging、recovery 等实际产物时，才能与该原卷重挂共存。原还原记录保留；其他重叠、占用入口和不规范路径仍拒绝。持久化干预提示使用相同判据重新评估，不靠忽略所有预留解锁。

10 月 2 日兼容复查的“普通重挂遵循系统设置”描述，已由 10 月 9 日显式 legacy noowners 分流修订。不能因为主动还原曾切换 owners，就让后台普通重挂统一切换；更广的 copying/verified 与已有基线恢复属于后续扩展。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/实施验收/compatibility-review-20261002/报告.md（S025），与同归档 S075 对照。

## Related decisions

- 主动严格还原的独立条件见[历史严格还原只映射目标根所有权](2026-10-02-legacy-volume-restore-ownership.md)。
- 重挂触发和实际卷位置证明见[按卷事件重试并核实实际挂载位置](2026-09-23-event-driven-container-remount.md)。

- 本篇仅覆盖窄的旧卷重挂；新默认及更多恢复状态待入库，见[普通 APFS 数据卷显式使用 noowners 与系统建卷](../../proposed/bug-fix/2026-10-13-apfs-noowners-volume-creation.md)。
- 部分复制与目标权限暴露的后续缺口见[微信事故：检查卸载后的本地入口必须先于卸载](../../proposed/bug-fix/2026-10-12-wechat-mount-recovery.md)。

## Alternatives considered

- **所有旧卷统一 owners**：可以套用同一严格校验，但把历史 UID/GID 投影变成访问障碍，并引入额外权限变更。
- **忽略所有还原记录以便重挂**：可以绕开自身预留，却会覆盖已产生暂存或属于其他操作的路径。

## Consequences

无产物的历史还原不会永久锁住正常重连。兼容范围保持很窄：部分复制、严格基线和历史权限切换由后续恢复决定处理；不能把本篇扩展成一律允许重挂或递归改权限。

## Verification

`AppPorts/Utils/ContainerVolumeMigrator.swift` 的 remount 路径与 `AppPortsTests/ContainerVolumeMigratorTests.swift`、`AppPortsTests/ContainerMountResumeTests.swift` 可核对卷身份、记录冷启动和占位拒绝。来源记载定向测试通过；没有操作安装版应用或用户数据。
