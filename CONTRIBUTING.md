# 贡献指南 | Contributing Guide

[简体中文](#简体中文) | [English](#english)   
# THANKS💗  
<a href="https://github.com/wzh4869/AppPorts/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=wzh4869/AppPorts" />
</a>


---

## 简体中文

感谢你关注 **AppPorts**！我们非常欢迎社区成员参与进来，无论是修复 Bug、改进文档还是添加新功能。

### 🚀 如何开始？

1.  **提交 Issue**：发现 Bug 或有新构思？请先搜索现有的 [Issues](https://github.com/wzh4869/AppPorts/issues)。如果没有相关的，请创建一个。
2.  **派生 (Fork) & 克隆**：将项目派生到你的账号下，并克隆到本地。
3.  **创建分支**：基于 `develop` 分支创建功能分支 (`git checkout -b feat/your-feature`) 或修复分支 (`git checkout -b fix/your-fix`)。
4.  **编写代码**：遵循 Swift 代码规范和项目既有风格。
5.  **本地测试**：在 Xcode 中运行并确保所有功能正常工作（详见下方测试要求）。
6.  **提交 PR**：将你的分支推送到你的仓库，并向 **AppPorts** 的 `develop` 分支提交 Pull Request。

### 🤖 关于 Vibe Coding

AppPorts 接受使用 AI 辅助工具（如 Cursor、GitHub Copilot、Claude 等）进行 Vibe Coding 开发。**但提交代码的质量和正确性由贡献者本人负责。**

- **AI 助手必须遵循项目根目录的 `CLAUDE.md`**，该文件定义了编码准则、架构规范、构建命令和开发流程。如 AI 助手未自动读取该文件，请在提示词中明确要求模型先阅读 `CLAUDE.md`
- 建议通过多个 AI 模型交叉验证生成代码的质量与安全性，避免单一模型的盲区
- AI 生成的代码可能不符合项目既有风格，提交前请进行人工审查
- AI 无法替代对 macOS 系统行为的理解，涉及文件系统操作、代码签名、权限管理等逻辑时请务必手动验证
- **核心功能**（如迁移策略、数据目录迁移、代码签名等）的变更必须先提交 Issue 讨论，获得确认后再执行开发

### 🧪 测试要求

> **所有 PR 必须通过编译烟雾检查，这是合并的硬性门槛。**

#### 必须通过：编译烟雾检查

```bash
xcodebuild clean build \
  -scheme "AppPorts" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 按需运行：专项测试

当 PR 涉及对应模块时，建议主动补跑专项测试。CI 会在独立的 macOS runner 上运行完整 `AppPortsTests` 回归测试，并单独运行本地化审计；两者共用一次 Debug 测试编译。PR 中这些结果仍为 Advisory，不阻塞合并。

请查看 `Tests (Advisory)` 的步骤摘要：它会分别显示通过、失败、取消或未运行；任务显示绿色不代表所有 Advisory 测试通过。日志和 `.xcresult` 诊断产物保存 5 天。新提交会取消同一 PR 的旧检查。

| 测试套件 | 涉及模块 | 运行时机 |
|----------|----------|----------|
| `DataDirMoverTests` | 数据目录迁移 | 涉及 `DataDirMover` 时 |
| `DataDirScannerTests` | 数据目录扫描 | 涉及 `DataDirScanner` 时 |
| `AppMigrationServiceTests` | 应用迁移 | 涉及 `AppMigrationService` 时 |
| `AppScannerTests` | 应用扫描 | 涉及 `AppScanner` 时 |
| `AppLoggerTests` | 日志与诊断 | 涉及 `AppLogger` 时 |
| `LocalizationAuditTests` | 本地化 | 涉及用户可见文案时 |

运行示例（数据目录测试）：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/DataDirMoverTests" \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### 🌐 本地化要求

- 本地化适配是推荐项，不作为外部贡献者提交 PR 的强制门槛。
- 如果 PR 新增、修改或删除了用户可见文案，欢迎在同一个 PR 中同步更新 `Localizable.xcstrings`；如果本次暂时不做，请在 PR 中简单说明原因或后续计划。
- SwiftUI 字面量仅限 `Text`、`Button`、`Label` 等 `LocalizedStringKey` 场景；AppKit/API 字符串仍建议显式使用 `.localized`。
- 动态文案仍建议优先使用格式化 key，例如 `String(format: "排序：%@".localized, value)`。
- 语言列表仍建议统一维护在 `AppLanguageCatalog`，不要在多个页面重复硬编码。
- 如果 PR 变更了菜单、弹窗、设置项、日志导出、错误提示、状态文案或 onboarding 文案，建议至少检查一次 `zh-Hans` 和 `en` 的实际显示结果。
- PR 的强制检查只保留编译烟雾检查；数据目录专项测试和本地化审计主要用于提供反馈，不再默认阻塞创新型改动。
- `main` / `develop` 在合并后会运行完整回归测试，测试必须通过；本地化审计仍提供 Advisory 反馈。随后执行 Release 编译并校验、上传未签名应用包。

更多规则见：[LOCALIZATION.md](LOCALIZATION.md)

### 🛠️ 代码提交规范

- **Issue 优先**：重要功能的变更请先通过 Issue 讨论。
- **保持原子化**：每个 PR 尽量只解决一个问题或添加一个功能。
- **清晰的注释**：为复杂的逻辑编写清晰的 Swift 文档注释。
- **Commit 信息建议**：
  - `feat: ...` (新功能)
  - `fix: ...` (修复 Bug)
  - `docs: ...` (文档更新)
  - `refactor: ...` (重构)
  - `test: ...` (测试相关)

### ❤️ 欢迎所有形式的贡献

我们特别欢迎：
- 针对 `AppScanner` 等核心逻辑的稳定性和性能改进。
- UI/UX 的优化，特别是符合 macOS 系统原生感的改进。
- 中英文档的同步和完善。

---

## English

Thank you for your interest in **AppPorts**! We welcome community contributions, whether it's fixing bugs, improving documentation, or adding new features.

### 🚀 How to Start?

1.  **Submit an Issue**: Found a bug or have a new idea? Please search existing [Issues](https://github.com/wzh4869/AppPorts/issues) first. If there isn't one, create a new one.
2.  **Fork & Clone**: Fork the project to your account and clone it locally.
3.  **Create a Branch**: Create a feature branch (`feat/your-feature`) or a fix branch (`fix/your-fix`) based on the `develop` branch.
4.  **Write Code**: Follow Swift coding conventions and the project's existing style.
5.  **Local Testing**: Run in Xcode and ensure all functions work correctly (see testing requirements below).
6.  **Submit a PR**: Push your branch to your repository and submit a Pull Request to the `develop` branch of **AppPorts**.

### 🤖 About Vibe Coding

AppPorts accepts Vibe Coding with AI-assisted tools (e.g., Cursor, GitHub Copilot, Claude). **However, the quality and correctness of submitted code is the contributor's responsibility.**

- **AI assistants must follow the `CLAUDE.md` file in the project root.** It defines coding guidelines, architecture conventions, build commands, and development workflows. If the AI assistant does not read it automatically, explicitly instruct the model to read `CLAUDE.md` in your prompt.
- Cross-validate AI-generated code quality and security with multiple models to avoid blind spots from a single model
- AI-generated code may not match the project's existing style — review it manually before committing
- AI cannot replace understanding of macOS system behavior — manually verify logic involving file system operations, code signing, and permission management
- **Core features** (e.g., migration strategy, data directory migration, code signing) must be discussed in an Issue first and confirmed before development begins

### 🧪 Testing Requirements

> **All PRs must pass the smoke build check — this is a hard requirement for merging.**

#### Required: Smoke Build

```bash
xcodebuild clean build \
  -scheme "AppPorts" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Recommended: Focused Tests

When a PR touches the relevant module, it is recommended to run focused tests. CI runs the full `AppPortsTests` regression suite and a separate localization audit on a disposable macOS runner, sharing one Debug test build. Both remain Advisory for PRs and do not block merging.

Read the `Tests (Advisory)` step summary for passed, failed, cancelled, or not-run results; a green advisory job does not mean every test passed. Logs and `.xcresult` diagnostic artifacts are retained for five days. A new commit cancels older checks for the same PR.

| Test Suite | Module | When to Run |
|------------|--------|-------------|
| `DataDirMoverTests` | Data directory migration | When touching `DataDirMover` |
| `DataDirScannerTests` | Data directory scanning | When touching `DataDirScanner` |
| `AppMigrationServiceTests` | App migration | When touching `AppMigrationService` |
| `AppScannerTests` | App scanning | When touching `AppScanner` |
| `AppLoggerTests` | Logging & diagnostics | When touching `AppLogger` |
| `LocalizationAuditTests` | Localization | When touching user-facing copy |

Example (data directory tests):

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/DataDirMoverTests" \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### 🌐 Localization Requirements

- Localization updates are recommended, not mandatory for every external contribution.
- If a PR adds, changes, or removes user-facing copy, contributors are encouraged to update `Localizable.xcstrings` in the same PR. If not, briefly explain the reason or follow-up plan in the PR description.
- SwiftUI literals are still best kept inside `LocalizedStringKey`-backed APIs, and AppKit / imperative strings are still recommended to use `.localized`.
- Dynamic text is still best modeled with format keys such as `String(format: "排序：%@".localized, value)`.
- The language list is still recommended to come from `AppLanguageCatalog`, not duplicated across views.
- If a PR changes menus, alerts, settings, exported diagnostics, error messages, status copy, or onboarding text, it is recommended to verify the rendered result in at least `zh-Hans` and `en`.
- CI still runs localization auditing for feedback, but localization results are no longer a blocking merge requirement for PRs.
- After merging to `main` / `develop`, the full regression suite must pass; localization remains advisory. CI then builds Release, validates the app bundle and ZIP, and uploads the unsigned app.

See [LOCALIZATION.md](LOCALIZATION.md) for the full workflow.

### 🛠️ Commit Guidelines

- **Issue First**: Discuss major changes via an Issue first.
- **Keep it Atomic**: Try to keep each PR focused on a single issue or feature.
- **Clear Comments**: Write clear Swift documentation comments for complex logic.
- **Commit Message Suggestions**:
  - `feat: ...` (New feature)
  - `fix: ...` (Bug fix)
  - `docs: ...` (Documentation update)
  - `refactor: ...` (Refactoring)
  - `test: ...` (Testing)

### ❤️ All Contributions are Welcome

We especially welcome:
- Stability and performance improvements for core logic like `AppScanner`.
- UI/UX optimizations, especially improvements that match the native macOS feel.
- Synchronization and improvement of Chinese and English documentation.

感谢你的每一份贡献！ | Thank you for every contribution!
