# Agent Note: 迁移与手动签名分离，手动签名只保留临时候选

Status: implemented

> 迁移自 worktree data-ownership-compatibility / docs/superpowers/specs/2026-10-10-appports-business-logic-design.md

> 实现基线：迁移前已提交的 main 0e6eef3。当前工作区有相反路线的未提交修改，见关联 proposed 笔记；本篇不描述那份工作副本。

## Problem

把用户允许重签扩展成“每次签名都必须长期可撤销”，再嵌入数据迁移，会增加完整备份、差分格式和跨服务状态，占用原本希望释放的空间。旧偏好也不能成为当前真实应用的新签名授权。

## Decision

已提交实现中，迁移与还原只改变存放位置，保留真实应用签名；自建启动壳可签自己的代码。手动重签是绑定当前真实对象和版本的独立选择，迁移不通过旧全局偏好或登录脚本补签。经典模式只决定可用迁移方式，尚未适配沙盒的仅搬数据结果不能宣称已证明可访问。

独立签名使用一份同卷临时工作包，在候选中修改与严格校验，交换后自动清理旧包；不自动创建新的长期 snapshot、反向差分或 retired 原包。临时容量按可能完整复制预留，clone 只作优化。确认明确说明没有自动保存的离线撤销原件；恢复官方状态可用匹配官方原包或重装。

旧版本有效备份仍可恢复，不因新策略删除。小型签名事实独立于恢复字节，绑定真实安装、版本和原身份；没有旧备份也能通过匹配官方原件修复。签名/entitlements 读取失败不是“非沙盒”，不得绕过确认；恢复官方沙盒包前检查相关经典数据与应用组依赖，扫描失败不能视为无依赖。

候选在写内容前登记归属，交换前保存原包和候选身份；取消、崩溃和清理失败按实际对象续作，不自动再次签名。仅处理签名确实要求的内容，不为验签删除未知文件。完成且无引用后只保留小型事实；旧恢复材料在无法证明冗余时保留。

## Related decisions

- 诊断及官方恢复引导继续遵守[签名恢复引导必须区分异常与无法检查](../bug-fix/2026-09-26-signature-repair-guidance.md)。
- 重新保留可恢复原包属于另一个待入库决定，见[保留仍有恢复价值的签名原包](../../proposed/architecture/2026-10-12-recoverable-signature-backups.md)。
- 位置迁移的提交、恢复和更新保护锁的归属见[迁移以持久化切换和可重试清理为完成依据](2026-10-10-verified-transfer-lifecycle.md)；签名不得重放旧快照锁或递归清除来源未知的锁。

## Alternatives considered

- **强制把完整备份搬到外盘**：改动相对少且保留原件，但仍有整包占用、外盘依赖和生命周期维护。
- **自研反向差分**：可能节省空间并提供离线撤销，却增加基线依赖、持久格式和重建验证；已提交路线不采用。
- **每次保存完整原包**：恢复最直接，但与减少隐藏空间及维护负担的选择相反；后续重新引入原包的提案另记，不覆盖本篇理由。

## Consequences

位置迁移不再承担签名副作用，新签名只需要操作期的完整候选。代价是没有新增永久备份时，回到官方状态需要用户获得匹配原件；严格验签成功仍不保证启动、钥匙串或应用组可用。旧有效备份兼容与未知历史材料保留仍需要维护。

## Verification

提交 `45778dc` 及 HEAD 的 `AppPorts/Services/DataMigrationWorkflow.swift`、`AppPorts/Services/CodeSigner.swift`、`AppPorts/Services/SignatureFactStore.swift` 是本篇基线。当前主工作区已存在相反的未提交备份改动，因此源码核对应区分 Git 版本与工作文件。`AppPortsTests/SignatureOperationTests.swift` 和 `AppPortsTests/SignatureRecoveryDependencyTests.swift` 提供签名与依赖回归入口；本次不执行真实重签。
