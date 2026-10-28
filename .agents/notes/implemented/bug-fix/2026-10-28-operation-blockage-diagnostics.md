# Agent Note: 保留操作受阻原因并贯通诊断输出

Status: implemented

## Problem

Issue #81 诊断中的“已有文件操作或签名准备尚未完成”混合文件锁竞争和持久化签名事务，综合维护又把不同子系统警告压成字符串。锁文件不可访问也被布尔返回值伪装成忙碌。弹窗、任务中心和导出摘要因此不能定位受阻操作及其关联记录。

## Decision

锁执行仍保留既有 bool/锁语义，额外记录最近失败的真实类别和 syscall 错误。诊断错误区分全局锁、签名锁、锁文件不可访问、writer admission、未完成签名、备份搬迁/依赖及应用迁移元数据；只有确知的记录 ID/阶段/应用路径进入关联信息。flock 不能证明持有者身份，owner 保持 unknown。

OperationBlockage 通过 CustomNSError 携带稳定诊断码与字段。AppLogger 统一提取结构化字段及 underlying NSError，并用既有操作摘要记录失败。任务执行失败关联任务 ID 和实际进度阶段；签名后台维护在转成警告字符串前逐项记录具体上下文。用户提示给出具体原因、下一步和可用的关联记录编号，不承诺未知事务会自动恢复。当前手动签名材料尚无任务中心处理入口，因此提示稍后重试、持续失败则导出诊断包，不引导用户寻找不存在的恢复按钮。现有任务历史沿用文本消息，不改执行账本和 schema。

## Existing-note audit

- [签名恢复引导](../../implemented/bug-fix/2026-09-26-signature-repair-guidance.md)：部分重叠，未知保持未知，不改变恢复权限。
- [诊断导出](../../implemented/process/2026-10-21-诊断导出与应用清单选择.md)：部分重叠，保留默认排除应用清单、后台导出、脱敏和原子替换。
- [后台任务](../../implemented/architecture/2026-10-21-后台迁移任务与异常处理.md)：部分重叠，丰富失败消息及诊断，不改变调度、重试与恢复权威来源。
- 活跃 proposed/rejected 未发现相同方案；上述现行记录均保留，不归档。

数据副本清理进一步记录具体路径、阶段和原始 NSError，并区分最新数据位置，见[旧数据副本授权清理](2026-10-28-data-cleanup-administrator-authorization.md)。

## Alternatives considered

- 仅替换弹窗文字：变更小，但原因在抛错和字符串聚合时已经丢失，无法知道具体阻塞记录。
- 新建持久化锁持有者登记：可展示更多实时上下文，但引入新的跨进程协议及过期身份处理。本次不推测 flock 的持有者。
- 把任务历史改成执行账本：可保存更多结构，但混淆展示和恢复权限；沿用现有摘要和自由文本显示历史。

## Testing

相关回归 200 项通过（100 项 XCTest、100 项 Swift Testing），覆盖隔离文件锁竞争、不可访问、非法文件、admission 和错误重置，签名阻塞记录、损坏记录、真实交换后清理失败，以及原始签名备份保留中断。任务中心测试确认 attention 状态、历史重载文本和任务 ID/执行尝试 ID/阻塞记录关联。实际诊断包导出保留稳定码、阶段和底层错误，同时用户名/外盘名脱敏。独立进程写锁测试另通过 4 项。

Release 双架构 `xcodebuild clean build` 成功。功能日志 `/tmp/AppPortsIssue81-diagnostics-final-tests.log`，构建日志 `/tmp/AppPortsIssue81-diagnostics-final-release.log`。提示修正后补充回归 36 项通过（24 项 XCTest、12 项 Swift Testing，含上述 4 项跨进程测试）；本地化审计仍仅同样 3 项失败。补充日志见 `/tmp/AppPortsIssue81-diagnostics-guidance-tests.log`。本地化新增 7 条诊断文案均覆盖 22 种语言；全库审计仍有 3 项既有失败，分别涉及 stale 状态和旧键缺失翻译，未将它报告为全绿。完整测试套件未在本机运行，遵循一次性 runner 的仓库要求。

签名锁错误的调用方断言包含 `SignatureBackupCleanupTests.respectsSignatureLock`：它持有真实文件锁，检查 `.signatureLockBusy` 并确认备份记录字节不变。合并后 CI 曾因该测试仍要求旧 `SigningError` 类型而失败；这是遗漏的测试契约更新，不通过放宽锁或删除备份不变断言修复。修正后完整运行 SignatureBackupCleanup、CodeSigner、SignatureOperation 与 OperationLock，共118项通过（13项XCTest、105项Swift Testing），日志 `/tmp/AppPortsLatest-signature-regression.log`；未将专项通过等同于远端全量CI已通过。

## Consequences

同一失败可从弹窗、任务历史和导出日志关联到已知记录，文件锁不可访问不再伪装成忙碌，成功后收尾失败也保留原始诊断。代价是维护稳定诊断码、NSError 桥接及全部语言的对应文案；这些信息属于时间点观察，不提供锁持有者证明。只有可验证的记录 ID 和应用身份进入关联字段，损坏文件中未经验证的路径单列为 recorded_application_path。

本次不改变执行权限、锁调度、恢复判定和 schema；任务历史仍只是展示历史。未知或未接入界面的签名异常仍可能需要诊断后人工处理，增加具体提示不代表自动修复完成。若后续提供签名材料管理界面，再将对应提示指向真实的操作入口。
