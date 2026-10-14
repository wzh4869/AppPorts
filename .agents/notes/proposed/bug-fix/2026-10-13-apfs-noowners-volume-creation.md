# Agent Note: 普通 APFS 数据卷显式使用 noowners 与系统建卷

Status: proposed

> 迁移自 docs/superpowers/reports/2026-10-12-legacy-noowners-restore.md
> 迁移自 docs/apfs-wechat-validation-2026-10-13.md
> 迁移自 docs/apfs-cross-app-validation-2026-10-14.md

> 入库状态：本机已有实现与来源报告所述验证，相关源码尚未提交；按已确认的迁移约定暂记 proposed，随对应代码提交再转换。

> 已确认方向：普通 APFS 迁移使用 diskutil 建卷和 noowners 挂载；proposed 仅表示对应源码待入库。维护时延续这一默认，不按旧 implemented 笔记恢复 newfs/owners。显式严格历史事务的原证据仍须正确解释，不能反向成为普通迁移的全局门槛。

## Problem

owners 挂载会暴露 root 所有、0755 的新卷根，普通用户即使具有完整磁盘访问也可能无法写入。为设置 UID/GID 改用 newfs_apfs 后，镜像测试成功却在物理外盘遇到裸设备权限失败；旧还原反复切换 owners/noowners 进一步引入授权与重试障碍。

## Proposal

普通数据卷使用 `diskutil apfs addVolume … -nomount`，明确以 `noowners` 挂载，检查真实可写性，并用容器 UUID、创建前后唯一新增卷和卷标记绑定产物。不要依赖卷名猜测或失败后重复建卷。

缺少权限字段的旧挂载采用同一默认语义；已经明确持久化严格 owners 契约的事务保持原契约，不改写已采集快照。尚未认领目标、没有复制基线及暂存的旧失败还原可经原子身份检查转换；已有基线只在能证明所有权投影相容时接续。

恢复、取消、重连和完成记录必须保持同一来源所有权解释。当前容器可读、旧本地副本缺失不等于不可还原；不因权限兼容而跳过内容、可移植元数据、身份或清理检查。v1.9.0 标签未显式指定 noowners，不能声称回滚就能解决所有设备的权限问题。

## Existing evidence

2026-10-12 旧卷报告记录不必要的 owners 切换与原始错误丢失；来源没有确定重启后瞬时错误消失的原因。10 月 13 日报告记录系统建卷及真实微信往返，10 月 14 日纠正了 v1.9.0 默认行为。主工作区的 `DiskUtility`、挂载记录和恢复实现包含这些未提交变化。

## Related decisions

- 历史严格主动还原的根映射继续按其持久凭据解释，见[历史严格还原只映射目标根所有权](../../implemented/bug-fix/2026-10-02-legacy-volume-restore-ownership.md)；这不改变普通新迁移的 diskutil/noowners 默认。
- noowners 兼容不取消其他复制证明，见[目录显示、执行权限与严格数据复制分开约束](../../implemented/architecture/2026-10-01-data-path-copy-safety.md)。

- 已有的窄重挂兼容继续独立约束，见[旧容器重连保持原有所有权语义](../../implemented/bug-fix/2026-10-07-legacy-container-remount.md)。
- 普通入口的自动恢复与清理见[由持久化事务自动完成 APFS 恢复与清理](../architecture/2026-10-12-apfs-automatic-recovery.md)。
- 此提案改变已提交的建卷选择，两篇保留各自理由，见[专用 APFS 卷通过真实所有权保留源元数据](../../implemented/architecture/2026-10-01-apfs-owners-volume-creation.md)。
- 普通树复制的两侧所有权语义不等于专用卷默认，见[普通数据复制分别遵守源与目标所有权语义](../../implemented/architecture/2026-10-09-data-ownership-compatibility.md)。
- 本篇与已提交相反路线并存的迁移依据见[将决策笔记集中到随仓库维护的 Agent Notes](../../implemented/process/2026-10-14-agent-notes-adoption.md)。

## Alternatives considered

- **newfs_apfs 初始化真实 UID/GID、所有新卷 owners**：保留真实所有权的理由成立，也在隔离镜像工作，但物理设备权限与普通使用配置暴露了额外限制。
- **统一启用整个外盘所有权**：能减少单次语义差异，却影响无关文件和应用，不是普通迁移的前提。
- **删除所有元数据校验**：能避开 UID/GID 错误，但无法区分兼容复制和未验证复制；仅投影所有权，不放弃其他证明。

## Acceptance criteria

普通新卷及缺省旧记录无需所有权转换完成迁出、使用、还原和清理；显式严格记录仍受原基线约束。在线、离线、部分复制、取消、冷重试覆盖同一来源契约。未创建卷的事务须确认容器事实才结束，原始与恢复 NSError 的代码和路径均可诊断。代码与笔记同批提交后转 implemented。

## Risks

noowners 不保证任意文件系统保留所有元数据，也不取代 TCC 授权。物理外盘与镜像行为不能互推，历史严格快照的解释必须稳定；本方案不改整盘设置、不递归 chown/chmod。
