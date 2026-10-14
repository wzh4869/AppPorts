# Agent Note: 迁移以持久化切换和可重试清理为完成依据

Status: implemented

> 迁移自 worktree data-ownership-compatibility / docs/superpowers/specs/2026-10-10-appports-business-logic-design.md
> 补充取舍来源 worktree migration-safety / docs/plans/2026-10-01-migration-safety.md

## Problem

复制成功不代表入口已切换或空间已释放。中断后重新复制可能制造更多副本，按旧基线限制已激活位置又会拒绝正常新写入；仅有内存状态不能在崩溃后判断哪份数据有效。

## Decision

应用和数据迁移复用各自的持久记录、复制验证和操作锁；应用转移有自己的 journal，不另套父 workflow，也不将签名绑进数据账本。正常路径包括准备、验证、切换、实际清理与完成。位置已生效而 Dock、入口维护或旧副本清理失败，只重试对应待办。

创建意图与父目录/卷身份先落盘，再独占创建；实际产物身份确认后才写内容。来源未切换时可继续或取消已证明归属的准备；创建后尚未记账的对象不能按名称猜归属。未知材料保留并通过现有处理路径呈现，不建立第二个完整副本。

切换前持久化候选身份、验证事实及入口意图。切换后活动数据可正常改变，原复制基线只用于未激活候选与旧副本删除；恢复读取当前活动数据。冷重试以实际入口和凭据确认切换，只补记账时不重放旧根元数据。

应用替换保留旧版直到候选通过并提交；同名不等于同对象。复制与提交前检查运行状态，已提交后旧实例还在运行时延后删旧包。签名原本有效的目标须保持有效；未签名或损坏的应用按原状态搬迁，不顺手修复。

数据及其副本不由 AppPorts 加不可变锁。应用的显式更新保护单独管理，只撤销能证明由 AppPorts 自己施加的锁；迁回本地不重新施加外盘保护。旧快照中的锁不是签名内容，不能自动重放。来源未知的锁保留并给出具体处理动作，不能通过递归清除属性来强行完成操作。

写出顺序包含内容与必要元数据、验证、切换意图、入口与完成记录，再删除旧对象。账本采用临时文件同步、同卷 rename 和父目录同步；错误不被吞掉。切换前失败保留源，切换后失败暂停清理。不能把 atomic write、正常卸载或 SIGKILL 测试当成断电安全证明。

## Recovery evidence and predecessor dependencies

旧七阶段试验覆盖 preparing、copying、verified、switching、awaitingUserVerification、cleanupRequested、needsRecovery：落盘后冷建 store/scanner/migrator 两次，核对原 ID、路径、身份、基线、实际内容与记录不变。它证明历史材料可被识别，不证明进程被杀或物理断电后的自动恢复；其中“冷开只读、等待人工验收”是当时流程，不能恢复成当前自动协调的禁令。

真实 APFS 实验里，旧副本被独立 writer 持有时清理拒绝；当前数据还原后，更新的保留卷仍依赖尚未处理的前驱。清理必须按保留链证明每份材料可删，不能仅因最新事务结束就越过旧的独立内容。后续自动收尾承担这项责任，不要求普通用户逐份认领副本。

物理删除失败与删除成功但最终记账失败是两个状态：前者仍有材料，后者材料已不存在但账本未完成。重试按实际身份和持久凭据补足欠项，不重新复制或宣称第二次释放空间。私有恢复点已挂源卷也须按身份复用，不能因卷内有数据而当成空落点冲突。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/实施验收/implementation/phase-reentry-report.md（S036），以及同归档 S006、S021、S023、S057、S066。

## Related decisions

- 严格旧还原的根映射、同 ID 重试与私有恢复点见[历史严格还原只映射目标根所有权](../bug-fix/2026-10-02-legacy-volume-restore-ownership.md)。

- 位置切换后的列表反馈由[应用列表即时发布与手动大小重测](../bug-fix/2026-09-30-app-list-refresh.md)。
- 进一步统一自动恢复与内部维护的待入库扩展见[由持久化事务自动完成 APFS 恢复与清理](../../proposed/architecture/2026-10-12-apfs-automatic-recovery.md)。
- 签名备份的待入库选择不纳入迁移父工作流，见[保留仍有恢复价值的签名原包](../../proposed/architecture/2026-10-12-recoverable-signature-backups.md)。
- 后台 writer 的身份和登记竞态扩展见[后台写入者准入绑定实际进程与代理签名](../../proposed/bug-fix/2026-10-13-background-writer-identity.md)。
- 应用本体的原基线一次清理重试扩展见[清理观察失败只按原基线立即重试一次](../../proposed/bug-fix/2026-10-14-cleanup-baseline-retry.md)。
- 迁移不拥有独立签名副作用，见[迁移与手动签名分离，手动签名只保留临时候选](2026-10-10-independent-manual-signing.md)。

## Alternatives considered

- **签名与数据合成父 workflow**：可集中串联步骤，但把独立签名及其恢复材料变成释放空间的前提，增加跨服务状态。
- **用户逐份验证后才清理所有原件**：保留直观撤销机会，却让正常成功仍占源空间，并要求用户判断内部副本；采用已验证切换后自动清理，可证明不足的材料继续保留。
- **切换后仍要求活动数据等于复制基线**：检查统一，却把正常使用的新写入误判为失败；当前有效位置与旧副本必须分别验证。

## Consequences

重试只完成尚欠步骤，活动新数据与已提交位置不会被旧候选覆盖。代价是每种变更都要保存足够的归属和同步证据；旧版本能力不足不能由 schema 号魔法隔离。无完整凭据的材料可能保留；只有实际删除成功才报告相应空间释放。

## Verification

实现依据为 `45778dc` 后的 `AppTransferTransaction`、`DataDirMover`、`ContainerMountStore`、`DurableFileIO`。可从 `AppPortsTests/AppTransferTransactionTests.swift`、`AppPortsTests/DataPreparationRecoveryTests.swift`、`AppPortsTests/DurableFileIOTests.swift` 核对四类准备中断、激活后写入和失败保留。来源 v3 中 4 GiB/10 万文件及 RSS 数值是待测门槛，不是本次或已提交代码的性能通过结论。
