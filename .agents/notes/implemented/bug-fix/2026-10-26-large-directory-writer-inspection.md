# Agent Note: 大目录写入者检查采用独立超时预算

Status: implemented

## Problem

[Issue #93](https://github.com/wzh4869/AppPorts/issues/93) 报告微信 msg 目录约 140 万文件、228 GB，`lsof +D` 热缓存运行约 32 秒，超过 `DataOperationSafety.requireNoKnownWriters` 的 30 秒上限。迁移在复制开始前反复失败，界面只显示通用安全检查失败，无法区分超时与其他检查错误。报告者把上限设为 1800 秒后成功迁移；这属于报告者提供的证据，不是本次本机复现。

## Decision

目录仍通过 `lsof -nP -F pcfa +D <path>` 检查，但采用 1800 秒上限；单文件沿用 `-- <path>` 和 30 秒上限。正常完成立即返回，不等待预算耗尽。`+D` 需要遍历目录树，预算放宽使已知百万文件场景不再受 30 秒门槛阻断；检查方法、描述符写入判定和执行时复查位置保持原有契约。

超时抛出独立的 `inspectionTimedOut`，提示“数据安全检查超时，已停止操作并保留数据”，全部 22 种语言均有对应文案。权限诊断继续优先映射为访问被拒绝；超时结果即使含部分只读输出也不能授权操作，其他退出错误和非空诊断继续拒绝。

## Existing-note audit

- [严格数据复制与执行安全](../architecture/2026-10-01-data-path-copy-safety.md)部分重叠：本篇只改变检查预算及错误分类，独立写入者、锁与原件保全的限制继续适用；`lsof` 仍是观察而非阻止后续写入的锁。
- [企业微信容器保护](2026-10-01-wecom-container-integrity.md)部分重叠：共用执行安全入口，但路径策略与历史还原规则不变。
- [小文件复制批次](../architecture/2026-10-24-small-file-copy-batches.md)仅验证背景相关：本篇不改变复制、同步和退出时序。
- [所有权测试镜像卸载](../testing/2026-10-15-ownership-image-detach.md)无关：该处 `lsof` 仅用于失败后的有界诊断，保留其五秒上限。

检索覆盖 proposed、implemented、rejected；无完全吸收或需要否决的旧提案。

## Alternatives considered

- **全量 lsof 后按路径过滤**：避免递归目录遍历，潜在开销与打开文件数相关；但需要重新验证路径别名、硬链接和完整输出的检测语义。本次保留已使用的目录选择机制，不把性能改造混入超时修复。
- **按文件数量动态预算**：预算能随规模调整，但需要额外扫描或可信计数，且文件数量不能可靠预测存储、缓存和权限检查延迟。采用报告者验证过的有界固定预算。
- **保留 30 秒上限**：失败返回快，但直接拒绝报告中约 32 秒即可完成的正常检查，无法满足本次修复目标。

## Consequences

已知慢检查有更充足的完成时间，仍无法完成的检查可明确诊断。代价是慢或卡住的目录检查最多等待 30 分钟，目录遍历本身并未提速，多处执行时复查仍会重复付出扫描成本。超过新上限仍拒绝操作，不承诺任意规模都能迁移；若实际延迟不可接受，应以独立性能改造验证全量枚举或其他系统接口。

## Verification

`DataOperationSafetyTests` 覆盖目录/单文件参数及超时预算、无写入者、超时及部分只读输出、权限诊断、异常退出、非空诊断和已知写入者；原有真实子进程持有文件测试继续验证系统 `lsof` 检测。注入测试不实际等待 1800 秒，也不重建报告者的百万文件目录。

2026-10-26 本机验证：

- 使用 `/Volumes/hano/Applications/Xcode.app/Contents/Developer`，`xcodebuild clean build -scheme AppPorts -configuration Release -destination 'platform=macOS'`（关闭签名、独立 DerivedData）成功，包含 arm64 和 x86_64。日志 `/tmp/appports-issue93-release.log`。
- 同一目录的 Debug `xcodebuild test` 选择 `DataOperationSafetyTests`、`DataDirMoverTests`、`ContainerVolumeMigratorTests`、`LocalizationAuditTests`，关闭测试运行器并行。三个安全与迁移套件共 142 项测试通过，包括真实子进程写入者检测。
- 本地化 19 项中 18 项通过；全语言翻译完整性审计因既有 `%lld / %lld` 缺译失败，因此组合测试命令退出 65。该条目与 HEAD 的 JSON 内容完全一致，仅有状态为 new 的 zh-Hans 值；本次新增提示的 22 种语言和每种语言的单个 `%@` 均已核对完整。结果 `build/Issue93-Tests.xcresult`，日志 `/tmp/appports-issue93-tests.log`。不将这一轮表述为全绿。
- 独立只读代码审查无待修问题；决策笔记树、格式、归档校验和 `git diff --check` 通过。

本次没有在报告者的机器或真实微信 msg 目录重演迁移，也没有运行全套回归或更新 main。
