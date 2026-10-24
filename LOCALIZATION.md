# 本地化指南 | Localization Guide

## 简体中文

### 目标

AppPorts 的本地化不再依赖人工记忆，而是依赖三层约束：

1. `Localizable.xcstrings` 作为 UI 文案唯一翻译源
2. `AppLanguageCatalog` 作为支持语言唯一数据源
3. `LocalizationAuditTests` 作为自动审计守门员

### 当前架构

- 字符串目录：`AppPorts/Localizable.xcstrings`
- 语言注册表：`AppPorts/Models/AppLanguageOption.swift`
- 语言切换：`AppPorts/Utils/LanguageManager.swift`
- 自动审计测试：`AppPortsTests/LocalizationAuditTests.swift`

### 翻译范围与验证责任

外部贡献者可以延后完整翻译，但下列代码接入规则仍适用。请在 PR 中列出未完成的文案、语言、实际回退显示和后续计划。AI 助手按 `CLAUDE.md` 与维护者确认范围；不要复制英文充当完成翻译或放宽审计来隐藏缺译。PR 的本地化 CI 为 Advisory，具体贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 开发规则

1. SwiftUI 纯字面量文案可以直接写在支持 `LocalizedStringKey` 的组件里。

```swift
Text("选择文件夹")
Button("清空日志") { ... }
Label("设置", systemImage: "gearshape")
```

2. 任何 AppKit / imperative API 文案必须显式 `.localized`。

```swift
panel.prompt = "选择文件夹".localized
alert.messageText = "无法迁移".localized
```

3. 动态拼接文案必须用格式化 key，不要直接字符串插值。

```swift
Text(String(format: "排序：%@".localized, selectedSortMode.rawValue.localized))
```

原因：
- 不同语言的语序不同
- 字符串目录能单独翻译整句
- 自动测试可以检查 key 是否缺翻译

4. 语言名称不要散落在 UI 代码里，统一从 `AppLanguageCatalog` 读取。

说明：
- 语言名称使用各语言自称（autonym），这是刻意设计，不走普通 UI 翻译流程
- 新增语言时，只改 `AppLanguageCatalog` 和 `Localizable.xcstrings`

5. 新增用户可见文案后，必须确保它进入 `Localizable.xcstrings`。

### 如何检查

在本地运行：

```bash
xcodebuild -project AppPorts.xcodeproj -scheme AppPorts -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/LocalizationAudit -only-testing:AppPortsTests/LocalizationAuditTests test
```

`LocalizationAuditTests` 会检查：

- 每个 string catalog key 是否覆盖所有受支持语言
- 是否存在未本地化的 AppKit 文案赋值
- UI 文件里是否返回了疑似未本地化的显示字符串

### 新增语言的步骤

1. 在 `AppLanguageCatalog` 里注册新语言代码、名称、旗帜和是否 AI 翻译
2. 为 `Localizable.xcstrings` 补齐该语言所有 key
3. 在本地运行 `xcodebuild test`
4. 提交 PR

### 不该做的事

- 不要在多个文件重复维护语言菜单
- 不要把 `"\(value)"` 这种插值句子直接当可翻译文案
- 不要假设 SwiftUI 之外的字符串会自动本地化
- 不要只测当前系统语言

---

## English

### Goal

AppPorts localization is now guarded by automation instead of memory:

1. `Localizable.xcstrings` is the single translation source for UI copy
2. `AppLanguageCatalog` is the single source of truth for supported languages
3. `LocalizationAuditTests` detects missing translations and unsafe raw strings

### Translation scope and verification responsibilities

External contributors may defer complete translations, but the code-integration rules below still apply. List deferred text, languages, actual fallback display, and follow-up plans in the PR. AI assistants confirm scope with the maintainer under `CLAUDE.md`; do not copy English as a completed translation or weaken auditing to hide gaps. Localization CI is advisory on PRs; see [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow.

### Rules

1. SwiftUI literal strings are acceptable only in APIs that use `LocalizedStringKey`.
2. AppKit / imperative strings must call `.localized`.
3. Dynamic sentences must use a format key from the string catalog.
4. Language names must come from `AppLanguageCatalog`, not duplicated in UI code.
5. Every new user-facing string must exist in `Localizable.xcstrings`.

### Validation

Run:

```bash
xcodebuild -project AppPorts.xcodeproj -scheme AppPorts -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/LocalizationAudit -only-testing:AppPortsTests/LocalizationAuditTests test
```

The localization audit tests verify:

- every string-catalog key has translations for all supported locales
- imperative AppKit properties do not receive raw user-facing strings
- UI files do not return likely user-facing raw strings without localization
