# Agent Note: 普通数据复制分别遵守源与目标所有权语义

Status: implemented

> 迁移自 worktree data-ownership-compatibility / docs/superpowers/specs/2026-10-09-ownership-compatibility-design.md

## Problem

用户正常使用“忽略所有权”的外盘时，严格 UID/GID 比较会在尚未产生目标数据前拒绝复制，还可能留下 needsRecovery 锁住完整原目录。要求修改整盘设置会影响无关文件和应用。

## Decision

`TreeCopySnapshot.OwnershipCompatibility` 分别记录源、目标实际所有权语义，不把目标例外写回源条目。owners → owners 保留严格 UID/GID；owners → noowners 保持源严格、容忍目标投影；noowners → owners 保存源可见证据并明确核对恢复目标的当前用户；两边 noowners 时各遵守自身语义。

内容、模式、ACL、应用扩展属性、时间和硬链接仍按复制模式校验；这不是允许向无法表示元数据的文件系统进行有损复制。没有兼容字段的旧快照按严格含义读取。所有权兼容至少需要账本 schema 5；当前账本还按其他字段需要升级，不能把总版本固定成 5，也不能允许旧 writer 丢字段后重解释。

尚未开始的符号链接迁移只有在操作锁下重读精确事务、原件未变、目标父目录可访问且目标/备份/staging 均不存在时，才可只移除匹配记录。该取消不删除任何文件；部分复制、身份变化和未知产物仍保留记录。

旧主动还原的目标根映射从 schema 4 开始记录，真实旧 writer 的兼容实验说明字段丢失会破坏源/目标解释；本篇的两侧兼容是后续 schema 5+ 的独立扩展。版本号和实际 writer 能力一起防止降级覆盖，不能只升级数字而不检查写入者。

策略意图与完成记录一起原子持久化，不能先删除验证材料再依赖零散字段重建。中间版本已经丢失的所有权证据不得按卷名或残留字段猜回；普通缺省兼容与明确严格契约按各自已记录的含义处理。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/实施验收/compatibility-review-20261002/报告.md（S025），以及同归档 S060–S062。

## Related decisions

- 历史主动还原的源/目标根分离见[历史严格还原只映射目标根所有权](../bug-fix/2026-10-02-legacy-volume-restore-ownership.md)。

- 专用 APFS 卷默认的后续选择另记，见[普通 APFS 数据卷显式使用 noowners 与系统建卷](../../proposed/bug-fix/2026-10-13-apfs-noowners-volume-creation.md)。
- 这是严格复制的所有权兼容维度，其他证明仍由[目录显示、执行权限与严格数据复制分开约束](2026-10-01-data-path-copy-safety.md)。

## Alternatives considered

- **启用整个目标卷所有权**：能统一核验模型，却改变其他数据的访问行为，不能作为普通复制的默认修复。
- **取消所有元数据验证**：减少兼容错误，但失去确认完整复制的能力。
- **保留原始条目、独立记录两侧语义**：需要快照与 schema 演进，却能支持常见外盘配置并准确说明验证了什么，因此采用。

## Consequences

普通数据迁移不因 noowners 配置本身失败，源与旧副本的严格证明也不被目标例外污染。代价是复制、恢复、根元数据和清理必须共同解释兼容字段；格式版本与实际 writer 准入缺一不可。APFS 专用卷如何创建/挂载属于另一决定。

## Verification

`d10396a` 与 HEAD 的 `TreeCopySnapshot`、`ContainerMountStore` 提供实现依据；定向入口为 `AppPortsTests/TreeCopyOwnershipTests.swift`、`AppPortsTests/DataTransferOwnershipSchemaTests.swift`、`AppPortsTests/DataPreparationRecoveryTests.swift`。来源要求真实隔离 noowners 镜像验证；此次笔记迁移仅核对实现，不新做磁盘实验。
