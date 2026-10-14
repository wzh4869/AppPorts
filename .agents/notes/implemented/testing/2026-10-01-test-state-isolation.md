# Agent Note: 测试注入目录还必须隔离记录库和共享日志

Status: implemented

> 迁移自 worktree migration-safety / docs/plans/2026-10-01-migration-safety.md
> 迁移自 worktree migration-safety / docs/reports/2026-10-01-migration-safety-verification.md

## Problem

迁移安全测试虽注入合成 home，却仍使用默认 ContainerMountStore.shared，向真实记录写入了四条合成链接和两条事务。只隔离输入目录不够，默认存储和日志仍可能污染用户状态。

## Decision

XCTest 下默认/共享记录库落在稳定的进程专属临时目录，测试还显式注入各自的记录库。共享日志也使用测试临时目录，避免追加或轮换生产日志。隔离回归验证不会读写真实记录，不能只根据构造器的 home 参数推断隔离有效。

真实卷实验使用独立合成目录和可核实归属的镜像，禁用管理员执行和生产代理同步；清理核对镜像、容器、卷身份，成功后卸载自有介质，失败保存诊断。独立宿主身份与进程级隔离的后续扩展由关联测试笔记记录。

## Incident facts

来源记录真实的两条微信挂载内容未变，测试未迁移真实应用数据。处置保留污染现场，先证明恢复文档内容与实施前 SHA-256 一致，再持操作锁和记录写锁、确认无新变化后原子恢复。内容逐字节恢复，但 inode 和 mtime 因替换改变，不能宣称整个文件对象未动。早期日志也可能被写入或轮换，此事实不被后续隔离修复掩盖。

## Evidence design and limits

复制保全使用独立清单核对根与子项的内容、权限、ACL、应用 xattr、时间、链接和硬链组，不把生产复制器与自身快照的一致性作为唯一证据。原生最终验收含 11 组、每组 13 项的独立比对；补充验收另有 6 组。旧静止清单与闭合数据库不能覆盖写入期一致性。

真实子挂载分别放在源、目标 staging 和保留原件内，核对 UUID、哨兵及拒绝后完整性；不能用“选定根本身就是卷”冒充嵌套覆盖。独立 Python SQLite 进程保持 WAL 连接，COMMIT 返回后源 101 行、候选 100 行且两者 integrity=ok；复制切换前拒绝，旧副本清理在 writer 退出后仍因原基线变化拒绝。这比任意文件追加或 writer 关闭后的快照更准确地覆盖数据库晚写入。

七阶段冷加载是持久状态模拟，不是 kill 或断电。fake disk runner 的 UUID、规范路径和 mode-000 夹具检查也有前提；错误的 symlink GID、URL 缓存注入未生效或错误读取封闭占位目录，是需要修正的夹具问题，不能把失败包装成生产缺陷，也不能把绕开夹具后的成功扩展为真实设备覆盖。

测试预置的合法探针创建/删除也会改变根 mtime，独立验证清单须对应正确时点；不能用过期夹具基线误报缺陷。这不授权生产清理重新采集基线来接纳后来写入，删除仍依据实际复制并持久化的原始证明。

历史全量记录含 48 条 warning，UI 导出跳过项不计通过；arm64/x86_64 编译不证明 Intel 运行或最低 macOS 运行。原生 APFS 强拔也有 SQLite malformed 的证据，正常卸载和故障注入不能替代该风险。此次只核对归档与实现，不重跑测试，也不将这些历史结果赋给后来的 build 30。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/实施验收/native-apfs-05-final/REPORT.md（S057），以及同归档 S021、S027、S035–S036、S058–S059、S079。

## Related decisions

- 独立宿主、真实卷和性能对照的待入库策略见[隔离 APFS 验证与可比较的性能证据](../../proposed/testing/2026-10-12-apfs-validation-evidence.md)。

## Alternatives considered

- **只注入合成 home、保留默认单例**：测试搭建简单，但其他持久化入口仍落在用户域，已实际污染记录。
- **仅靠每个调用者记得注入**：可以隔离正确编写的测试，却容易遗漏默认或共享路径；默认测试隔离与显式注入共同防护。

## Consequences

遗漏单个依赖注入不再直接触达生产记录，隔离依据可被回归检查。代价是要维护测试环境识别和独立存储生命周期；仍不能由库级隔离推断任何测试进程、代理或真实盘操作都已隔离。

## Verification

已提交的 `AppPortsTests/ContainerMountStoreIsolationTests.swift`、`AppPorts/Services/ContainerMountStore.swift` 和 `AppPorts/Services/AppLogger.swift` 可核对隔离实现。来源的全量回归与镜像实验是 2026-10-01 的历史证据；本次不重演污染、不读取或重写生产记录。
