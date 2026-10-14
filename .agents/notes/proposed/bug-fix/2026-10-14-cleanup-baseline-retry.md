# Agent Note: 清理观察失败只按原基线立即重试一次

Status: proposed

> 迁移自 docs/apfs-cross-app-validation-2026-10-14.md

> 入库状态：本机已有实现与来源报告所述验证，相关源码尚未提交；按已确认的迁移约定暂记 proposed，随对应代码提交再转换。

## Problem

应用本体已切换后，一次 sourceChanged 或 verificationFailed 会立即显示待办；后台随即用原基线成功清理时，界面还保留失败结果。直接重建基线来消除提示又可能把真正改变的旧副本误认为可删。

## Proposal

`AppTransferTransaction` 对这两类清理校验错误在原操作内立即重新核验一次，始终使用原持久化基线及身份。只重试清理，不重新复制、切换、重签或采纳新基线。持续差异继续保留旧副本并返回准确的待办。

该策略针对应用本体清理，不自动泛化到所有错误、数据迁移或任意重试次数。已激活的新位置允许合法写入；旧副本的删除依据保持不变。

## Existing evidence

2026-10-14 来源记录 build 29 的 Obsidian 迁出曾提示待办，随后后台清理完成。build 30 加入原基线立即重试，Maccy、IINA、Obsidian 本体往返完成收尾；`AppTransferTransactionTests` 57 项通过。当前相关修改尚未提交，历史失败不被后续成功覆盖。

## Related decisions

- 此提案只改变应用清理观察重试，完成语义仍由[迁移以持久化切换和可重试清理为完成依据](../../implemented/architecture/2026-10-10-verified-transfer-lifecycle.md)。

## Alternatives considered

- **第一次观察失败立即转后台待办**：服务流程简单，但短暂失败会留下已经过时的用户提示。
- **重新建立基线或重新迁移**：可能绕过当前差异，却把旧副本的新内容变成删除依据，或重复已经提交的位置切换。

## Acceptance criteria

一次观察失败可在原操作内恢复；复制和切换各只发生一次。活动数据新写入保留，旧副本持续变化时立即重试与后续重试都拒绝删除。错误不在限定集合内不自动扩张重试。对应源码、测试提交后转 implemented。

## Risks

一次重试增加一次核验成本，不保证所有暂时性错误消失；真实差异仍可能要求保留材料。来源的多应用文件比对不替代所有签名/xattr 验收，部分还原后的原入口 UI 确认仍未完成。
