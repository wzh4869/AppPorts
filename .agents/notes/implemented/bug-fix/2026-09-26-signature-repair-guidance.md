# Agent Note: 签名恢复引导必须区分异常与无法检查

Status: implemented

> 迁移自 docs/design/2026-09-26-migration-onboarding-review.md

## Problem

把签名探测失败当作已替换或已修好，会误导用户重签名或丢弃恢复材料；将通用名称片段当作容器归属还会让修复面板要求还原无关应用的数据。

## Decision

签名诊断针对解析后的真实应用，不针对本地启动壳。当前明确为 ad-hoc 且有原开发者身份依据时，才确认签名替换；读取失败、超时或外盘不可读保留为待检查。仅有备份不证明签名操作已成功，原生 ad-hoc 应用也不能因此被判定为受损。

恢复沙盒官方包前检查实际经典容器链接依赖。已经使用 APFS 挂载的数据不因签名修复而一律迁回。完整匹配原包可用于恢复；只有覆盖安装分支才按需要求迁回应用。当前开发者签名与完整修复是不同判断，最终仍须核对签名有效性与应用使用。

扫描不能用 CN 等地区、平台通用词关联无关容器。更完整的归属由独立身份与目录策略决定，修复面板不自行扩大匹配范围。

## Related decisions

- 签名恢复与磁盘预检部分重叠；按当前存储状态继续任务见[按当前任务进行 APFS 迁移预检](../feature/2026-09-24-apfs-migration-preflight.md)。
- 恢复候选的只读身份解析另有归属，见[应用数据扫描使用真实应用身份](2026-09-29-app-data-identity.md)。
- 新手动签名的已提交备份选择由[迁移与手动签名分离，手动签名只保留临时候选](../architecture/2026-10-10-independent-manual-signing.md)。

## Alternatives considered

- **用“有备份”认定已重签**：容易实现，但备份在操作前产生，失败的重签也可能留下它。
- **探测失败时直接再签一次**：可能暂时改变签名状态，却掩盖路径、权限或身份问题，并可能进一步破坏沙盒和 TCC 关联。
- **恢复前一律迁回应用与所有数据**：步骤统一，但对完整原包恢复及有效 APFS 挂载引入无关操作。

## Consequences

未知状态不会被伪装为确定结论，修复只处理相关依赖。代价是离线或探测失败时需要重试，并且成功验签本身不保证钥匙串、应用组和启动行为。新签名是否保存长期原包由独立签名笔记规定，本篇不扩大这一承诺。

## Verification

可核对 `AppPorts/Utils/AppScanner.swift`、`AppPorts/Views/SignatureRepairSheet.swift`、`AppPortsTests/AppScannerSignatureCheckTests.swift` 与 `AppPortsTests/SignatureRepairSafetyTests.swift`。来源的 89 项定向验证和界面检查属于 2026-09-26，当时没有执行真实数据迁移或重签；本次只迁移决定与限制。
