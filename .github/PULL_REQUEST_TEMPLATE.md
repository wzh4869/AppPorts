## 📝 变更说明 | Description
<!-- [CN] 请简要描述本次 PR 的主要内容、解决的问题或实现的功能 -->
<!-- [EN] Please briefly describe the main changes, issues fixed, or features implemented in this PR -->

## 🔗 关联 Issue | Related Issues
<!-- [CN] 请在下方引用关联的 Issue，例如：Fixes #123 -->
<!-- [EN] Please reference related issues below, e.g., Fixes #123 -->

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

## 🌐 本地化影响 | Localization Impact
> 如本次 PR 涉及任何用户可见文案、菜单、弹窗、设置项、错误提示、日志导出文案或状态文案，欢迎同步完成本地化适配；当然可以暂时不做，也可以在 PR 说明里写清原因或后续计划。  
> Localization is recommended for user-facing copy changes, but it is not mandatory for every PR. If you are not doing it in this PR, please briefly explain why or note a follow-up plan.

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
