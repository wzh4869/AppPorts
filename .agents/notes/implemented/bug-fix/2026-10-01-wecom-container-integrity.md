# Agent Note: 企业微信复盘：保护容器骨架并保留历史还原

Status: implemented

> 迁移自合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/底层根因报告.md（S003）
> 补充来源：同归档 S001–S005、S008–S019、S063、S076–S077；冻结报告与原始证据保留在归档。

## Problem

Issue #65 中，AppPorts 复制并挂载企业微信的 `Data/tmp` 成功，应用随后却在沙盒初始化时 SIGTRAP。只看迁移命令结果，或只禁止这一个目录，都会遗漏同类启动损坏；直接隐藏旧记录又会堵住还原出口。

## Decision

`DataPathPolicy` 保护普通容器根、`Data` 和相对于 `Data` 的 11 个精确结构节点：`Documents`、`Library`、`Library/Application Scripts`、`Library/Application Support`、`Library/Caches`、`Library/Images`、`Library/Logs`、`Library/Preferences`、`Library/Saved Application State`、`SystemData`、`tmp`。扫描可展示锁定结构，执行入口独立拒绝以卷或软链接替换这些节点。历史受管项仍可发现、可从专用恢复路径还原。

普通结构保护不自动禁止全部业务后代；微信 `com.tencent.xinWeChat` 另保留白名单，只允许 `Data/Documents/xwechat_files` 下的直接账户子目录和 `Data/Library/Application Support/com.tencent.xinWeChat`。因此微信 tmp 后代仍被锁定，不能用其他普通容器的通用资格推断微信可迁移。

Group Containers 的根保护、布局及共享授权单独处理，不把普通容器固定表原样套过去。显示候选、系统结构合格和应用实际工作流兼容是不同结论。

## Root cause and evidence limits

macOS 27.0 / 26A428 的 AppContainer 原函数先比较 Data 与容器父目录的设备号，再对固定表中存在的条目检查真实目录类型和 `st_dev`；不存在条目可跳过，其他检查错误不能忽略。企业微信真实日志明确为 `directory tmp is on a different device`，沿完整性检查失败传播到 secinitd 和 libsystem_secinit。汇总 `EINVAL` 不表示挂载系统调用失败。

这里的设备号是文件系统身份。同一物理盘的不同 APFS 卷也可不同；相同格式无法豁免。隔离探针直接调用系统原函数：tmp 外置和 tmp 本地软链接均失败，普通业务子目录挂载通过。该函数不递归检查所有后代，也不能代表全部 macOS 安全机制。

真实 Data 入口以 O_SEARCH/O_NOFOLLOW_ANY 打开，不能把先宽松 open 再调用 validator 的通过结果当成真实启动接受软链。固定条目缺失会跳过，不表示可以删掉结构作为迁移方案；中间目录缺少搜索权限仍可令检查失败，未直接比较 mode 不等于权限无关。已有注册的 EEXIST 或 profile 缓存也不能跳过先发生的完整性检查。

真实企业微信四个业务目录的 15 种组合启动通过；UpgradeBeta、Wedoc、AIModel 缺真实数据验证。微信标识的原函数探针不等于真实微信 tmp 迁移或启动实验。原签名、运行进程身份与 profile 调用顺序证据排除了本次用 SDK、profile 缓存或 ad-hoc 分类解释两应用差异的假说，不能推出重签名是通用绕过方案。

内核注册的静态审计只限定已追踪调用树：有效 FD、目录、规范路径与注册权限仍有要求；其中未发现同样的递归固定结构表，不等于内核、Seatbelt、TCC 或文件系统没有其他约束。早期“只比较路径字符串”的概括不作为迁移保证。

## Related decisions

- 执行拓扑与复制保全见[目录显示、执行权限与严格数据复制分开约束](../architecture/2026-10-01-data-path-copy-safety.md)。
- 子目录通过结构检查后的运行时取舍见[临时目录的结构资格与迁移推荐分开](../../proposed/feature/2026-10-01-temporary-directory-migration-policy.md)。
- 迁移执行者和目标应用权限分开，见[按当前任务进行 APFS 迁移预检](../feature/2026-09-24-apfs-migration-preflight.md)。
- 各层验证不互相替代，见[隔离 APFS 验证与可比较的性能证据](../../proposed/testing/2026-10-12-apfs-validation-evidence.md)。

## Alternatives considered

- **只禁 tmp**：直接挡住已复现崩溃，但同一检查还覆盖其他结构节点，不能遗漏它们。
- **禁用整个容器或所有结构后代**：边界简单，却阻止已经通过真实启动的业务路径，也不能解释原有微信成功层级；保护精确节点并保留应用例外。
- **改成软链接或重签名绕过**：软链接可保持路径外观，重签名可能改变某些初始化分支；但 tmp 软链接直接违反目录类型要求，外部链接还受运行时授权约束，改变签名身份也不能作为普适修复。

## Consequences

结构级崩溃在服务入口被阻止，历史误迁移仍有恢复出口。代价是维护系统结构知识与应用例外；固定表来自特定系统实现，不能当成永久公开 API。系统升级或应用改变数据布局时，应重新验证结构与真实工作流，不能仅增加名称白名单。

## Verification

核对入口为 `AppPorts/Models/DataPathPolicy.swift`、`AppPortsTests/DataPathPolicyTests.swift` 和 `AppPortsTests/DataOperationSafetyTests.swift`。归档的真实崩溃、原函数探针、静态分析与组合启动分别支撑上述范围；此次仅迁移笔记，不重演真实应用故障。
