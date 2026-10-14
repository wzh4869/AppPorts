# Agent Note: 专用 APFS 卷通过真实所有权保留源元数据

Status: implemented

> 迁移自 worktree migration-safety / docs/plans/2026-10-01-migration-safety.md
> 迁移自 worktree migration-safety / docs/reports/2026-10-01-migration-safety-verification.md

> 实现基线：迁移前已提交的 main 0e6eef3。当前工作区有相反路线的未提交修改，见关联 proposed 笔记；本篇不描述那份工作副本。

> 维护边界：普通 APFS 迁移的后续方向已确认为 diskutil/noowners，本篇只解释历史实现及严格记录。不得因本篇位于 implemented 就把普通建卷或挂载默认改回 newfs/owners。后继篇的 proposed 是源码待入库标记，不表示默认路线仍待选择。

## Problem

严格保留 UID/GID 的数据复制，在 noowners 下只看到投影身份；切到 owners 又会暴露新卷根为 root 的问题。单纯在忽略所有权的视图中 chown，不能证明底层真实所有权已正确。

## Decision

已提交的专用卷路线使用 `newfs_apfs -A` 的非破坏性建卷形式明确初始化当前用户所有权，并在新卷每次挂载时使用和验证 owners。创建前后核对容器 UUID 与唯一新增卷，身份查询使用没有过时资源缓存的 URL。

这只作用于新专用卷，不启用整个外盘的全局所有权数据库，也不在观察时自动重挂正在使用的旧卷。失败或超时不盲目再次建卷或提升权限。严格历史基线保持其解释，不因复制目标允许所有权投影就抹去源记录的真实身份。

本篇记录 Git 中仍存在的路线；当前主工作区使用系统 diskutil/noowners 的后续变化另记为 proposed，不能把两种建卷决定合成一个现行机制。

## Related decisions

- 系统建卷与 noowners 的相反路线尚待源码入库，见[普通 APFS 数据卷显式使用 noowners 与系统建卷](../../proposed/bug-fix/2026-10-13-apfs-noowners-volume-creation.md)。
- 卷所有权是严格数据复制的一部分，见[目录显示、执行权限与严格数据复制分开约束](2026-10-01-data-path-copy-safety.md)。

## Alternatives considered

- **在 noowners 下改所有者**：避免切换访问视图，但投影无法证明真实 UID/GID 已修正，不能满足本路线的严格证明。
- **使用默认 root 卷根后直接 owners 挂载**：建卷简单，却可能使普通用户无法写入，必须处理建卷时的真实所有权。
- **修改整盘所有权设置**：可以统一视图，却扩大对无关数据的影响，不属于专用卷职责。

## Consequences

严格路线可以按真实所有权验证专用卷，代价是需要底层建卷能力与实际设备权限。隔离镜像成功不证明实体盘可用；后续来源已报告物理盘权限失败，这也是另立 noowners 决定而不改写本篇的原因。用户日常操作不得据本篇推断无需其他权限。

## Verification

HEAD 的 `AppPorts/Utils/DiskUtility.swift`、`AppPorts/Utils/ContainerVolumeMigrator.swift` 含建卷与 owners 挂载，来源 2026-10-01 报告说明根所有权问题及镜像测试。可核对 `AppPortsTests/DiskUtilityCreationTests.swift` 与 `AppPortsTests/ContainerVolumeMigratorTests.swift`。同一文件的未提交工作副本已经不同，不能仅打开工作文件反向宣称 Git 路线不存在。
