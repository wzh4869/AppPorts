## 📝 变更说明 | Description
<!-- [CN] 请简要描述本次 PR 的主要内容、解决的问题或实现的功能 -->
<!-- [EN] Please briefly describe the main changes, issues fixed, or features implemented in this PR -->

> 请基于最新的 `main` 创建分支，并将 PR 的目标分支设为 `main`。
>
> Create your branch from the latest `main` and target `main` in this PR.

## 🔗 关联 Issue | Related Issues
<!-- [CN] 请在下方引用关联的 Issue，例如：Fixes #123 -->
<!-- [EN] Please reference related issues below, e.g., Fixes #123 -->
> 重要功能可先通过 Issue 讨论，或加入 [QQ群 (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) 与群主讨论；后者由群主在 Issue 公示讨论结论，请关联该 Issue。
>
> Significant features may be discussed in an Issue or with the owner of the [QQ group (384270587)](https://qm.qq.com/q/BhhRJ2rDz4). For QQ discussions, link the Issue where the group owner published the conclusions.

## 🧪 测试情况 | Testing
- [ ] 已在本地 Xcode 环境运行通过 | Passed local Xcode build and run
- [ ] 如有需要，已运行专项测试（如数据目录或本地化检查） | Ran focused tests if needed (for example data-directory or localization checks)
- [ ] 核心功能经过手动验证 | Core functions manually verified
- [ ] 修复了可能导致的权限或异常问题 | Fixed potential permission or exception issues

> PR 默认只要求通过编译烟雾检查。专项测试更适合在改动确实触及对应模块时主动补跑，而不是把所有创新型改动都挡在门外。  
> PRs are only required to pass the smoke build by default. Focused tests are encouraged when the PR touches the relevant module, instead of blocking all exploratory changes.

> CI 会自动运行完整回归测试和本地化审计，结果见 `Tests (Advisory)` 的摘要；绿色任务可能包含 Advisory 失败，请结合摘要和诊断产物检查。
>
> CI runs the full regression suite and localization audit. Read the `Tests (Advisory)` summary and diagnostic artifacts: a green job can include advisory failures.

## 📚 决策笔记与文档 | Decision Notes and Documentation

- 决策笔记链接，或纯机械改动等不适用原因 / Decision-note link, or reason it is not applicable:
- [ ] 如修改共享贡献规则，已同步根目录中英文、文档站三语指南及受影响的模板 | Shared contribution-rule changes are synchronized across root Chinese/English, all three site guides, and affected templates
- [ ] 如仅修改文档站，已运行 docs:build、docs:typecheck、docs:check，并同步三语正文和章节 ID | Documentation-site changes passed docs:build, docs:typecheck, and docs:check with synchronized translations and chapter IDs

> 请记录相关测试的通过、失败、跳过或未运行及原因。Advisory 不阻塞合并，但需要说明失败是否与本次改动有关。AI 修改已有测试覆盖的模块时，按 CLAUDE.md 运行对应测试。
>
> Report passed, failed, skipped, or not-run checks and reasons. Advisory failures do not block merging, but explain whether they relate to this change. AI changes to covered modules must run the relevant tests under CLAUDE.md.

## 🌐 本地化影响 | Localization Impact
> 如本次 PR 涉及任何用户可见文案、菜单、弹窗、设置项、错误提示、日志导出文案或状态文案，欢迎同步完成本地化适配；完整翻译可以延后，但代码仍须正确接入本地化，新增 key 须进入字符串目录。延后时说明受影响文案、语言、实际回退显示及后续计划。
>
> Complete translations may be deferred, but code must use the localization system and new keys must enter the catalog. If deferred, list affected text, languages, actual fallback display, and follow-up plans.

- [ ] 本 PR 不涉及任何用户可见文案 | This PR does not change any user-facing copy
- [ ] 如涉及用户可见文案，已同步更新 `Localizable.xcstrings` | If user-facing copy changed, `Localizable.xcstrings` was updated in this PR
- [ ] 如涉及用户可见文案，本次暂未同步本地化，已在说明中写明原因或后续计划 | If user-facing copy changed and localization was not included, I documented the reason or follow-up plan
- [ ] 如涉及用户可见文案，已检查至少 `zh-Hans` 与 `en` 的实际显示（可选） | If user-facing copy changed, I optionally verified the rendered result in at least `zh-Hans` and `en`
- [ ] 如涉及用户可见文案，已运行 `LocalizationAuditTests` 或等效本地化检查（可选） | If user-facing copy changed, I optionally ran `LocalizationAuditTests` or an equivalent localization check

## 📸 屏幕截图 | Screenshots (Optional)
<!-- [CN] 如果是 UI 相关的变更，请附上截图以供参考 -->
<!-- [EN] If this is a UI change, please attach screenshots for reference -->

---
*感谢你的贡献！ | Thank you for your contribution!*💗
