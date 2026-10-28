# Agent Note: 旧数据副本按需授权清理并显示当前数据位置

Status: implemented

## Problem

截图中的 Dortania 迁移旧副本属于 root、权限为 0755，普通进程清理时调整目录权限会失败。账本只留下“操作不被允许”，界面仅显示最早的路径；该数据实际上已经还原到本地，旧迁移记录仍在等待清理，用户无法区分当前数据与旧副本。现有管理员入口只支持应用本体事务。

## Decision

复用现有系统密码框、临时请求文件和当前可执行文件的一次性入口，扩展数据副本清理请求。普通用户进程持有操作锁并写账本，管理员进程只调用既有严格清单清理器，不运行 GUI、不写账本、不改当前数据或所有者。仅用户指定记录主动重试，在普通清理实际返回 EPERM/EACCES、已记录清理检查点且旧副本属 root 时授权；后台与批量自动处理不弹密码框。取消授权保留旧副本和可重试检查点。

请求沿用应用授权的文件读取规则，包含原迁移记录和当前有效位置。管理员入口核对已完成切换、清理检查点、活动数据及旧副本/父目录身份，复用 removeVerifiedCopy 的原内容清单及断点删除；不另写 rm 或扩大为任意文件操作。界面明确管理员所有权、当前有效数据位置和保留副本位置，具体底层错误与阶段进入既有诊断日志。不增加 schema 或常驻特权服务。

## Existing-note audit

- [应用本体授权](../../implemented/bug-fix/2026-10-20-root应用迁移授权.md)：部分重叠，复用授权运输和请求读取，不改变应用交换与签名规则。
- [持久化切换](../../implemented/architecture/2026-10-10-verified-transfer-lifecycle.md)：部分重叠，普通进程仍保管账本，数据切换成功不会因清理错误回滚。
- [操作受阻诊断](../../implemented/bug-fix/2026-10-28-operation-blockage-diagnostics.md)：部分重叠，扩展数据清理上下文，不推断未知错误原因。
- 未发现同范围的 proposed/rejected；已有记录保留，不归档。

## Alternatives considered

- 只改错误文本：可以解释 root 所有权，但用户点击重试仍不能完成本次实际清理，因此提供显式授权继续。
- 递归 chown 或以管理员启动 GUI：可以绕过权限，但改变第三方数据的所有权或扩大整个进程权限，沿用已有一次性受限执行方式。
- 新安装常驻特权服务：可持续处理权限操作，但本次只需前台单次清理，增加部署及维护成本。

## Testing

`PrivilegedDataCleanupTests` 通过实际临时文件执行同一严格删除器，验证只删旧副本、当前目录身份/内容/元数据不变、旧迁移使用最新本地还原位置；有内容差异、缺少删除检查点、活动位置与旧副本重叠或活动对象被替换时保留文件。诊断测试确认记录 ID、路径、阶段和原始 POSIX 错误经过 NSError 桥接保留。未为这些测试增加 mock 删除器。

`DataDirMoverTests` 的真实迁移→规范化→还原流程验证所有历史记录均显示最新本地数据位置。两个生产入口（应用数据页、任务中心异常恢复）共用 completedLocation 解析，在后台加载路径映射。首轮数据/应用迁移、账本及维护回归165项通过；最终 UI 路径接线后数据和清理测试通过。应用迁移复跑曾有3项被测试宿主正常退出中断（退出码0，不是断言失败），单独完整复验76项通过；原因未确认，不修改退出逻辑，也不将这次中断隐藏为全程全绿。最终源码的专项合计165项通过。日志 `/tmp/AppPortsDataCleanup-regression.log`、`/tmp/AppPortsDataCleanup-final-regression.log`、`/tmp/AppPortsDataCleanup-app-transfer-retry.log`。

最终 arm64/x86_64 Release clean build 通过，日志 `/tmp/AppPortsDataCleanup-release.log`。新增5条文案覆盖22语言，br和zh-martian按现有约定生成。中英德波阿五种语言的亮/暗界面渲染通过，并检查中英阿恢复界面的当前数据及保留副本标签，输出 `/tmp/AppPortsDataCleanupUI/`。`LocalizationAuditTests` 仍为同样3项既有失败（stale条目及旧键缺失翻译），本次5条新文案没有新增审计失败；日志 `/tmp/AppPortsDataCleanup-localization-ui.log`。界面fixture不模拟已获得root权限。

系统密码框、实际root提升及取消密码框未自动执行：当前没有可用的非交互sudo凭据，不以普通用户临时目录测试声称权限流程实机通过。完整套件未在本机运行。

截图现场仅只读核对：本地当前目录身份与最新restore记录匹配，旧副本uid为0，文件摘要同时匹配原清单和当前本地文件。没有改动截图中的旧副本、当前数据或用户权限。

## Local installation

维护者明确要求构建最新工作区代码并替换原应用。此次签名版Release clean build通过，产物为工程当前版本2.0.0（50），arm64/x86_64双架构；没有修改工程版本号。沿用原安装的Apple Development证书、团队MQ7XG7WM3F及com.shimoko.AppPorts标识，designated requirement与原安装一致，替换后 `codesign --verify --deep --strict` 通过。原安装1.9.9（50）保留为 `~/Library/Application Support/AppPorts/backups/AppPorts-before-local-20261028-161840.app`，新包替换 `/Applications/AppPorts.app`，未自动打开GUI。安装日志 `/tmp/AppPortsLatest-install-result.json`，构建日志 `/tmp/AppPortsLatest-signed-release.log`。

本次本地安装不是远端版本发布。管理员入口不具备root身份时从实际签名产物退出、没有进入GUI；该检查不代替真实密码框授权与root删除验收。

## Consequences

实际root旧副本可以在指定记录重试时调用系统授权继续清理，界面同时解释管理员所有权和两份数据的位置。代价是维护一个只支持symlink旧数据副本的管理员请求；它与应用授权共用临时请求格式和密码框运输，普通进程仍掌握日志、锁和账本。

系统决定是否复用近期凭据，不保证每次都会重新输入密码。只有普通清理已经写出删除检查点的权限失败可以授权，不扩大挂载卷删除权限，也不扩展管理标记删除前即失败的分支。其他失败仍保留材料并报告具体错误；授权取消没有删除结果，不报告已完成。
