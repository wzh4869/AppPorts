# Agent Note: 历史严格还原只映射目标根所有权

Status: implemented

> 迁移自合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/实施验收/restore-noowners-compat/报告.md（S061）
> 补充来源：同归档 S025、S060、S062、S066。

> 实现基线：a6ffc90 及后续已提交的私有恢复修复。当前本机普通恢复已有 diskutil/noowners 的未提交扩展；本篇保留历史严格契约，不能据此要求所有旧卷切换 owners。

> 维护边界：继续按已有严格证据解释特定历史事务，不等于恢复普通迁移的旧限制。普通新卷及缺省旧记录沿用已确认的 diskutil/noowners 方向；后续兼容依据见关联笔记。

## Problem

旧版卷在 noowners 下看似归当前用户，真实卷根却是 root:wheel。新严格检查在复制前拒绝旧还原，又留下 needsRecovery 自锁；直接切 owners 并原样复制根所有权，也会使普通用户无法建立本地可写目录。这些预检失败不等于发现数据损坏。

## Decision

已提交的历史兼容路径只在主动还原且满足旧卷条件时验证真实源所有权，并仅为还原目标顶层目录记录当前用户 UID/GID 映射。源清单保持真实 UID/GID，子目录和文件不作递归映射。后台观察不切换正在使用的旧卷，也不递归 chown 或提权绕过权限。

在线旧卷若仍处于 noowners，先要求该视图的 UID/GID 符合运行用户。后续已提交兼容还覆盖已经 owners 的在线旧卷：无 ownershipPolicy、无先前验证清单且尚无根映射时，实际 uid 0 的源卷根无论在线或离线，都可记录当前用户的目标根映射。所有权标记在复制前持久化且不可事后改写；目标验证使用目标根语义，源与保留卷清理继续使用真实源基线。

未开始的旧还原可沿原 operationID 重试，前提是挂载记录、来源链和卷 UUID 一致，没有 inode/device、复制基线、目标身份或实际 staging/recovery 产物。预检应先于新事务副作用；未知或已有复制证据的记录不能一概删除。

失败只回滚本次尝试改变的挂载选项，保留实际安全标志，不重放旧记录覆盖后来状态。UUID 快路径缺失时使用完整查询；回滚错误同时进入原始错误与恢复记录。

私有恢复点已经挂着已证明归属的源卷时，重试检查卷身份与 writer 后复用它；卷内数据不被当成底层非空落点。未挂载的落点仍须检查底层目录，未知卷不能认领。

## Contract evolution

schema 4 是该根映射字段首次落盘的门槛：归档用真实旧 writer 验证拒绝未来格式，避免旧写入丢失字段。后续普通源/目标兼容需要 schema 5 或更高版本，不能把当前总版本固定在 4。

10 月 2 日原生实验保留原卷等待人工验收，是历史流程；后来的持久化自动清理接管正常完成路径。普通卷的 noowners 默认及部分复制/已有基线接续由后续笔记约束，不把本篇窄重试条件扩展成今天所有还原的统一门槛。

## Related decisions

- 普通复制两侧语义见[普通数据复制分别遵守源与目标所有权语义](../architecture/2026-10-09-data-ownership-compatibility.md)。
- 当前本机扩展见[普通 APFS 数据卷显式使用 noowners 与系统建卷](../../proposed/bug-fix/2026-10-13-apfs-noowners-volume-creation.md)。
- 普通旧卷重连与主动还原分开，见[旧容器重连保持原有所有权语义](2026-10-07-legacy-container-remount.md)。
- 保留链与自动清理见[迁移以持久化切换和可重试清理为完成依据](../architecture/2026-10-10-verified-transfer-lifecycle.md)。
- provenance 已提交窄例外与后续 MACL 扩展见[区分系统管理的标签与可移植应用元数据](../../proposed/bug-fix/2026-10-13-system-managed-metadata.md)。

## Alternatives considered

- **取消 requireOwners 后直接沿用严格复制**：看似只需去掉预检，但复制器仍要求可解释的源所有权，且目标 root 根与原可写入口不符。
- **重写源根为当前用户或递归 chown**：可以让目标可写，却污染源基线并扩大副作用；只为目标根记录显式映射。
- **删除所有失败事务重来**：可解除重叠阻塞，却可能遗失部分复制与未知材料的归属；只接续严格证明未开始的旧事务。

## Consequences

历史严格还原可区分真实源与本地目标，未开始的失败不再永久自锁。代价是维护根映射、schema、回滚和清理的一致解释。该历史方案的覆盖有限，不能声称它解决了后来 copying 阶段、实际物理盘或所有 TCC 问题。

## Verification

来源 a6ffc90 记录三个自有 APFS 镜像案例、668 项通过与 4 项 UI 导出跳过、两架构编译；没有真实微信还原。S025 后续七组原生案例补充已 owners 在线旧卷与真实旧 writer 验证。53e30131 的私有恢复重试测试先复现 mountPointNotEmpty 再修复。核对入口为 `ContainerVolumeMigrator`、`TreeCopySnapshot`、`ContainerMountStore` 及相应测试；本次不重跑历史实验。
