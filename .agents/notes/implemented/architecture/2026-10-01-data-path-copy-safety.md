# Agent Note: 目录显示、执行权限与严格数据复制分开约束

Status: implemented

> 迁移自 worktree migration-safety / docs/plans/2026-10-01-migration-safety.md
> 迁移自 worktree migration-safety / docs/reports/2026-10-01-migration-safety-verification.md

## Problem

显示更多目录若直接扩大迁移权限，会覆盖系统结构或与已管理父子目录冲突。复制 API 成功也不能证明 ACL、硬链接、元数据与内容完整，历史损坏记录若被当成空库则会进一步失去恢复依据。

## Decision

`DataPathPolicy` 以精确节点及每种操作能力表达结构保护：普通容器根、Data 和标准结构节点受保护，锁定不自动传播到全部业务后代；Group Containers 有独立根规则。微信候选仍受原白名单约束，显示开关不能新增迁移授权。

拓扑检查覆盖实际挂载、在线/离线记录、受管链接、事务、暂存、旧副本及父子和别名关系。父已迁移阻止新增子迁移，子受管阻止迁移父；层级转换先还原再迁移，不自动拆并。历史被禁止结构的恢复可用专用私有挂载，不把它重新授权为普通新迁移。

数据目录由独立 `TreeCopySession` 复制根及子项，校验内容、该模式的所有权、07777 权限、ACL、应用 xattr/资源叉、出生和修改时间、支持的标志及树内硬链接。链接按链接复制，不跟随嵌套挂载；树外硬链接、外部相对链接最终解析改变和无法保留的元数据拒绝。不能承诺 inode、ctime、atime 或物理压缩形式相同。

记录意图先于副作用，切换前保存阶段并复核源；原件删除使用实际复制并验证的基线，出现独立新内容不可强删。损坏、未来版本、不可读或非普通记录文件不能初始化为空库；读写在原子替换之外还有进程间锁。

挂载点租约检查底层目录身份与全部内容，.DS_Store 也不能被覆盖；挂载失败不以自动 chmod0700 绕开检查。恢复验证真实本地父目录，不能通过外置祖先或上级链接把“本地还原”写回外盘。

## Evidence and contract boundaries

合订归档的旧复制与往返实验证明：普通文件 SHA-256 相同且 API 返回成功，仍可能丢目录/根 ACL、flags 和跨兄弟目录硬链接。最终回调的晚写入使源从 19 字节变为 48 字节，旧迁移还原后却只剩 19 字节；另一独立 SQLite writer 已提交的源有 3 行，目标仅 1 行，两边 integrity_check 都为 ok。GUI 退出与 AppPorts 自身操作锁不能排除独立 writer，数据库可读也不证明保留了最新 COMMIT。

父树复制还可能跳过真正的子挂载，含挂载后代的祖先仍可能改名，所以只检查选定根是否为挂载点不够。mode 000 不能隔离同一用户，持有底层 FD 的进程仍可能访问或修改被覆盖目录；挂载失败后自动放宽为 0700 会允许本地新写入，后续重挂又可能遮住它们。租约、身份与内容复核限制风险，但不构成对任意不合作 writer 的原子隔离。

卷重新连接后 dev_t 可改变而 UUID 不变；保留卷重新核对 UUID、对象身份与原基线，不把旧设备号永久绑定。归档原生重编号案例证明这一点，不能简化成只比 UUID 就允许删除。

这些反例支持保全目标，不支持永久沿用所有早期限制：普通源/目标 noowners 语义已有兼容，普通 APFS 建卷的本机后续路线是 diskutil/noowners；系统管理标签有精确例外，FIFO 有独立支持方案，完整内容证明可复用。不能由 10 月 1 日实验中的 noowners 或特殊节点拒绝，推导今天一律 owners、一律拒绝特殊节点或一律重复扫描。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/迁移还原与异常场景调查.md（S006），以及同归档 S007、S013、S020–S023、S035、S057。

## Related decisions

- 精确结构保护的事故依据见[企业微信复盘：保护容器骨架并保留历史还原](../bug-fix/2026-10-01-wecom-container-integrity.md)。
- 普通 tmp 后代的结构资格不等于迁移推荐，见[临时目录的结构资格与迁移推荐分开](../../proposed/feature/2026-10-01-temporary-directory-migration-policy.md)。
- 普通专用卷的建卷默认见[普通 APFS 数据卷显式使用 noowners 与系统建卷](../../implemented/bug-fix/2026-10-13-apfs-noowners-volume-creation.md)。

- 减少重复核验的决定不改变本篇安全目标，见[复用复制验证结果，不用时间戳替代内容证明](../../implemented/simplification/2026-10-12-apfs-verification-reuse.md)。
- provenance 例外与 MACL 的扩展见[区分系统管理的标签与可移植应用元数据](../../implemented/bug-fix/2026-10-13-system-managed-metadata.md)。
- FIFO 支持单独记录，见[复制持久 FIFO 节点，不读取瞬时管道消息](../../implemented/bug-fix/2026-10-14-fifo-copy.md)。
- 源/目标所有权分别解释的已提交兼容见[普通数据复制分别遵守源与目标所有权语义](2026-10-09-data-ownership-compatibility.md)。
- 显示层不提供执行授权，呈现规则见[容器归属、个人目录链接与大小显示](../feature/2026-10-01-container-ownership-presentation.md)。
- 专用卷真实所有权的已提交建卷理由见[专用 APFS 卷通过真实所有权保留源元数据](2026-10-01-apfs-owners-volume-creation.md)。

2026-10-29 的[微信离线媒体入口只读保护](../bug-fix/2026-10-29-微信离线媒体入口只读保护.md)仅对精确 msg/business 成员采用 0500，接管这些入口的离线权限规则；原有身份、空目录和卸载前检查继续适用。

## Alternatives considered

- **界面隐藏结构即视为安全**：简单，但自定义入口、伪造标志和历史记录仍可到达服务；执行层必须独立拒绝。
- **锁定节点及所有后代**：容易实现，却封住结构下本来可迁移的业务目录和历史恢复出口。
- **沿用应用包复制器处理数据树**：减少新代码，却缺少数据迁移所需的完整树证明；保持应用复制行为独立。

## Consequences

新迁移权限与历史恢复能力可分别演进，目录可见性不会成为操作授权。代价是严格复制会拒绝部分文件类型或能力不足的文件系统，并增加验证成本；所有权、系统标签与 FIFO 的窄兼容分别由关联笔记约束。面对任意不合作写入者不能承诺原子隔离，同用户替换窗口也不能因持有 FD 就宣称消失。

## Verification

`AppPorts/Models/DataPathPolicy.swift`、`AppPorts/Services/DataPathTopology.swift` 与 `AppPortsTests/DataPathPolicyTests.swift`、`AppPortsTests/DataPathTopologyTests.swift`、`AppPortsTests/TreeCopySessionTests.swift` 是入口。来源的真实嵌套卷、SQLite WAL 和冷重启矩阵使用隔离材料；不代表真实微信新业务路径或断电全部通过。手工保留原件的旧流程已由后续持久化自动清理决定吸收，不在此恢复为当前要求。
