# Agent Note: 应用数据扫描使用真实应用身份

Status: implemented

> 迁移自 docs/superpowers/specs/2026-09-29-issue63-app-data-identity-design.md

## Problem

迁移后的 Stub 标识带有 `.appports.stub`，iOS 应用又可能把身份放在内层包装包。直接读取本地入口会漏掉鸣潮、崩坏3等应用的数据，并可能把通用 stub 后缀误当作归属依据。

## Decision

`AppIdentityResolver` 复用 `CodeSigner.resolveAppURL(at:)` 的真实目标解析，再只读读取身份。真实外层应用与提供标识的内层包分别保存；签名目标不因扫描解析而改成内层包。解析器不执行启动脚本。

身份优先取原生 `Contents/Info.plist`，再取根 plist、明确的 `WrappedBundle` 或唯一 `Wrapper` 子包。已存在但损坏的 plist、失效入口或多候选不能被别的候选掩盖。包装解析有路径边界、循环检查与深度上限，不遍历任意扩展或 Framework。空标识和 Stub 自身标识无效。

扫描每次解析一次真实身份。失败时仍可保留现有名称候选，但 `identityIssue` 独立于目录读取错误，空间摘要标记不完整；不得把无法识别后的空结果当作确认没有数据。刷新重新解析，结果写回仍受应用 ID 和 scan token 约束。短词名称匹配限制保持独立，不通过放宽 bh3、QQ 等词来补漏。

## Deferred

离线身份缓存不属于该决定的已实现范围。若增加缓存，必须只从在线真实包建立可核验的入口/目标绑定，目标或身份改变时失效；缓存不得成为签名、执行或迁移授权依据。

## Related decisions

- 身份解析与签名诊断部分重叠；本篇不改变签名目标，见[签名恢复引导必须区分异常与无法检查](2026-09-26-signature-repair-guidance.md)。
- 获得 bundle ID 不等于证明所有候选归属，目录显示范围见[容器归属、个人目录链接与大小显示](../feature/2026-10-01-container-ownership-presentation.md)。

## Alternatives considered

- **剥掉 `.appports.stub` 后缀**：能修复部分迁移入口，但无法验证真实身份，也不处理本地 iOS 包装。
- **一次统一扫描、签名、Dock 和运行检测**：能减少身份读取分散，却扩大 Issue 63 的范围，并可能改变破坏性操作的目标语义。
- **把离线身份缓存一起交付**：能改善断盘发现，但需要独立的持久化、绑定与失效设计，不是根因修复的前提。

## Consequences

只读发现能识别原生及包装身份，并诚实呈现不完整结果。代价是畸形或离线包可能只剩名称匹配，严格歧义检查也会拒绝猜测。容器夹具必须包含实际数据子目录，不能把空容器壳当作端到端成功。

## Verification

提交 `04e70cc` 和已提交的 `AppPorts/Utils/AppIdentityResolver.swift`、`AppPorts/Utils/DataDirScanner.swift` 提供实现依据。`AppPortsTests/AppIdentityResolverTests.swift`、`AppPortsTests/AppIdentityScannerTests.swift` 和 `AppPortsTests/DataDirSpaceSummaryTests.swift` 是可复核入口。来源方案的“未实施”是历史状态；真实游戏及设备的未测范围不因源码核对而自动消失。
