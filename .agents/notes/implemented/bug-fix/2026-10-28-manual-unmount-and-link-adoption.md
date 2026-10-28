# Agent Note: 保留单卷卸载意图并补齐旧软链接管

Status: implemented

## Problem

Issue #81 的日志显示单卷手动卸载后两秒即被代理挂回。已有整盘弹出暂停不表达单个目录的卸载意图。现有软链目标已在规范路径时，规范化提前返回，没有建立管理凭据；容器旧链接又被新迁移规则挡在恢复入口之前。

## Decision

单卷暂停以卷 UUID 和原路径存入迁移账本，先保存再卸载。后台挂载和恢复遵守暂停；明确挂载成功（含核实卷已在原路径挂载）才清除，重启和拔插不清除。移除活动挂载记录同时移除对应暂停。新账本版本及 writer capability 阻止旧客户端忽略暂停。整盘弹出规则独立生效。

普通旧软链在原目标上也能完成用户确认接管，保持入口身份并生成标记及索引。容器旧软链只提供确认后还原到本地，复用已有校验、事务及保留原数据机制，不自动重签或新建容器软链。不增加无记录 APFS 卷认领。恢复入口直接复用 `restoreAndComplete(item:progressHandler:)`；不额外传递确认时目标，也不在管理索引写入前新增重复身份复查。

界面把实际挂载/在线状态与 `autoMountPaused` 分开表示。卸载失败而仍挂载时显示两种事实并提供“恢复自动挂载”；此入口验证现有挂载后清除暂停，不先卸载数据。卷离线时保留离线状态和暂停徽章，不承诺重新插盘后自动接回。拆分微信账号聚合成员暂停状态，列表的两种行展示共用同一事实。

后台仍静默跳过暂停的事务；手动指定 operationID 重试必须返回“本次未执行”的原因，任务中心显示需要处理，而不是完成。检查先于清理决定变化，包含已切换事务的直接清理路径。

## Existing-note audit

- [按卷事件重挂](../../implemented/bug-fix/2026-09-23-event-driven-container-remount.md)：部分重叠，增加用户暂停准入，不替代身份校验。
- [主动整盘弹出](../../implemented/feature/2026-10-23-explicit-disk-ejection.md)：部分重叠，单卷暂停不按物理重连接清除。
- [现有软链解绑](../../implemented/feature/2026-10-26-现有软链强制解绑.md)：部分重叠，解绑保留外部数据；本次接管和迁回不把空目录当还原。
- [持久化迁移](../../implemented/architecture/2026-10-10-verified-transfer-lifecycle.md)：部分重叠，保留原有校验与清理边界。
- proposed/rejected 未发现同范围替代方案；不归档现有笔记。

## Alternatives considered

- 仅在当前进程暂停：状态简单，但代理和冷启动无法遵守。
- 复用整盘弹出暂停：已有跨进程准入，但会挡住同盘其他目录，且重新插盘会解除。
- 缺记录一律拒绝：保守且易实现，但无法完成用户明确要求的现有软链接管。改为核对当前链接、目标身份和冲突后建立新凭据，不推断历史归属。

- 给恢复入口传递确认时目标并重复复查文件身份：能拦截确认后目标被外部替换的情况，但 Issue #81 没有这种现场证据，也没有发生频率数据。按维护者要求去掉这部分新增防御，复用既有事务校验。

## Testing

隔离目录与假 diskutil 覆盖冷启动后暂停、未开始还原的后台恢复暂停、同盘其他卷不受影响、挂载失败保留暂停、成功解除、保存失败不卸载、卸载失败保留暂停。账本测试覆盖 schema 12 无暂停、schema 13 暂停、错误 UUID/路径和旧 schema 夹带暂停拒绝。规范路径接管后还原、冲突标记拒绝、容器旧链接恢复使用真实临时文件，不操作用户业务数据。

相关串行回归通过 150 项 XCTest 与 190 项 Swift Testing，共 340 项，日志 `/tmp/AppPortsIssue81-followup-regression.log`。覆盖 ContainerVolumeMigrator、ContainerMountResume/Safety/Agent、ContainerRemountLoop、DataDirMover、DataTransferStore、DataDirScanner、WriterAdmission、DiskEjection、MigrationTaskCenter、OperationMaintenanceProgress，以及一个模拟浏览器界面测试。没有运行完整测试套件。

挂载、待挂载、离线三种状态均与暂停同时显示；扫描回归也验证暂停字段单独变化能刷新行，拆分账号聚合成员暂停。初次扫描回归捕获字段只落入恢复分支的问题，共用 applyInspectionResult 修正后通过。显式暂停重试的回归还通过真实 MigrationTaskCenter 结果转换和持久化历史，断言 attention 而不是 completed；最后的 ContainerVolumeMigratorTests 91 项复跑通过，日志 `/tmp/AppPortsIssue81-followup-final-migrator.log`。卸载失败后的明确恢复保持卷挂载，命令记录证明没有再次卸载或挂载，原文件保持一致。

浅色、深色模拟界面渲染通过并人工检查，图片位于 `/tmp/AppPortsIssue81FollowupUI/manual-pause-light.png` 和同目录 `manual-pause-dark.png`。暂停徽章在固定宽度中缩放以保留中文完整提示，恢复按钮的紧凑布局保留独立的本地化辅助功能标签和提示。最后的渲染测试日志 `/tmp/AppPortsIssue81-followup-final-tests.log`。

四条新增文案覆盖全部 22 种语言。LocalizationAuditTests 仍有三项既有失败：旧 `%lld / %lld`、`%lld 个应用` 缺翻译及旧条目 stale，失败对应的现有 catalog 条目与 HEAD 逐项相同；本次没有修改这些条目，日志 `/tmp/AppPortsIssue81-followup-tests.log`。原并行组合在多个同步快照等待 GCD 批次时不再推进，已结束自有测试宿主，沿用 CI 的 `-parallel-testing-enabled NO` 重新验证，未修改扫描并发实现。

最终 arm64/x86_64 Release clean build 通过，日志 `/tmp/AppPortsIssue81-followup-final-release.log`。笔记树、格式、归档及 git diff --check 通过。独立复查提出的扫描字段接线问题已修复，复核未发现其他具体 P1/P2。

撤回额外目标参数与写索引前身份复查后，`DataDirMoverTests` 50 项及 `DataMigrationWorkflowTests` 4 项通过，使用真实临时目录验证旧软链接管与容器还原；日志 `/tmp/AppPortsIssue81-simplified-recovery-tests.log`。此最终源码的 arm64/x86_64 Release clean build 同样通过，日志 `/tmp/AppPortsIssue81-simplified-recovery-release.log`。

## Consequences

手动卸载不会再被后台恢复覆盖，同盘其他卷可以继续使用；代价是用户需要明确挂载，或在卷仍挂载时点击“恢复自动挂载”，才能恢复自动接回。暂停保存失败不卸载，卸载失败仍保留暂停。明确还原允许把数据迁回本地，活动记录移除时清除其暂停。schema 13 一经写入不降级；writer capability 为 `appports-verified-writer-v8-manual-mount-pause`，旧 GUI/代理必须退出，不能用旧客户端忽略新意图。

旧链接在用户确认后从当前事实建立管理凭据，而不是宣称找回了历史归属。容器旧链接只迁回，不新建软链，不重签应用。未知标记和其他记录占用仍由原有流程检查。缺失标记但已有索引时重新确认并补写标记，不静默提前返回。暂停和接管的模拟回归不替代 Issue #81 用户现场、实际拔插或企业微信登录网络验收；本轮不安装、启动或替换生产应用。
