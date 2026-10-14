# Agent Note: 按当前任务进行 APFS 迁移预检

Status: implemented

> 迁移自 docs/design/2026-09-26-migration-onboarding-review.md
> 迁移自 docs/superpowers/specs/2026-09-24-apfs-migration-experience.md

## Problem

只迁移应用本体的用户不需要先理解磁盘格式；需要迁移容器数据的用户却必须在操作前知道目标盘、空间和加密条件是否允许继续。把所有人送进格式向导，或只给一个帮助链接，都不能可靠地回答当前任务能否完成。

## Decision

容器迁移在操作入口运行只读 `MountMigrationPreflight`，按未选存储、离线、非 APFS、加密和空间不足等状态给出下一步。用户换盘后继续当前目录的检查。普通应用和普通目录不继承专用容器卷的 APFS 要求。

预检保留现有配置；不自动抹盘、缩分区或把加密数据迁到默认不加密的新卷。内部挂载使用 `nobrowse`，不修改 Finder 全局偏好；系统插盘时可能短暂自动挂载，不能承诺内部卷从不出现。确认内容解释真实存储位置、外盘依赖及首次系统授权，不承诺断盘后必然无损。

挂载执行者与目标应用使用数据的权限必须分别检查：AppPorts 能 mount 不代表原签名应用可读写；应用具有容器授权也不代表迁移进程具有父目录或底层入口的 FDA/TCC 权限。root 不代替这些授权。软链接实验中的外部路径拒绝，也不能推广成 APFS 原位挂载必须重签。

原生 APFS 强拔实验曾出现 SQLite malformed，需用 `.recover` 抢救；这足以否定“原生 APFS 必然无损”，但不能从有限样本算出通用故障率或宣布某种格式绝对安全。事务证明、数据库一致性与物理断线分别报告。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/R/User_docs/docs/research/unplug-test.md（S079，冻结研究快照），以及同归档 S004、S017、S076–S078。

## Related decisions

- 系统结构检查的范围见[企业微信复盘：保护容器骨架并保留历史还原](../bug-fix/2026-10-01-wecom-container-integrity.md)。
- 登录、解锁与实际挂载时机见[按卷事件重试并核实实际挂载位置](../bug-fix/2026-09-23-event-driven-container-remount.md)。

- 预检与签名诊断部分重叠；签名未知状态及恢复依赖由[签名恢复引导必须区分异常与无法检查](../bug-fix/2026-09-26-signature-repair-guidance.md)。
- 连续应用级流程尚未实施，扩展提案见[统一应用级迁移与修复引导](../../proposed/feature/2026-09-26-unified-migration-guidance.md)。

## Alternatives considered

- **首次启动强制格式向导**：可以集中解释 APFS，但会打断只迁应用本体的任务，还容易把换盘误解为所有用户的前提。
- **仅跳转文档**：维护成本低，却无法结合当前目录和磁盘状态指导下一步。
- **关闭加密后继续**：能绕过当前建卷限制，但新卷不继承同容器其他卷的密码，不能以降低用户原有保护换取迁移成功。

## Consequences

预检把阻塞条件放在变更前，保留用户已选内容。代价是需要维护可重试的状态与任务上下文；加密容器迁移在没有密码管理和自动解锁方案时仍不受支持。磁盘工具可见性、TCC 提示和物理断线行为受系统约束。

## Verification

实现入口为 `AppPorts/Utils/MountMigrationPreflight.swift`和 `AppPorts/Views/DataDirsView.swift`；回归入口是 `AppPortsTests/MountMigrationPreflightTests.swift`。来源记录预检、引导与本地化测试通过，但没有用该结果证明真实应用迁移或所有 Finder 时序。此次笔记迁移不重新执行磁盘操作。
