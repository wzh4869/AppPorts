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

1.  **反馈与讨论**：先搜索现有的 [Issues](https://github.com/wzh4869/AppPorts/issues)，避免重复反馈。重要功能的变更请先通过 [Issue](https://github.com/wzh4869/AppPorts/issues) 讨论，或者加入 [QQ群 (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) 向群主讨论；群内讨论后，由群主在 Issue 公示讨论结论。
2.  **派生 (Fork) & 克隆**：将项目派生到你的账号下，并克隆到本地。
3.  **创建分支**：基于 `main` 分支创建功能分支 (`git checkout -b feat/your-feature`) 或修复分支 (`git checkout -b fix/your-fix`)。
4.  **编写代码**：遵循 Swift 代码规范和项目既有风格。
5.  **本地测试**：在 Xcode 中运行并确保所有功能正常工作（详见下方测试要求）。
6.  **提交 PR**：将你的分支推送到你的仓库，并向 **AppPorts** 的 `main` 分支提交 Pull Request。

### 开发环境

- 应用运行支持 macOS 12 及以上；这不是开发环境的最低版本。开发需要完整 Xcode（仅安装 Command Line Tools 不够），测试工具链还须支持 Swift Testing。优先使用与当前 CI 一致的 Xcode；具体版本可从 Actions 的 Build environment 日志查看，仓库尚未声明经过验证的最低 Xcode 版本。
- 在 Xcode 中打开 `AppPorts.xcodeproj`，选择共享的 `AppPorts` scheme 和 My Mac。应用不使用 Swift Package Manager，也没有第三方 Swift 依赖。命令行验证使用下文的无签名参数，无需配置发布证书；本机运行时按实际操作授予所需权限。
- 先用 `xcodebuild -version` 检查当前工具链。Xcode 不在默认位置时，在当前终端设置 `DEVELOPER_DIR`，例如：

```bash
export DEVELOPER_DIR="/Volumes/<external-volume>/Applications/Xcode.app/Contents/Developer"
```

### 🤖 关于 Vibe Coding

AppPorts 接受使用 AI 辅助工具（如 Cursor、GitHub Copilot、Claude 等）进行 Vibe Coding 开发。**但提交代码的质量和正确性由贡献者本人负责。**

- **AI 助手必须遵循项目根目录的 `CLAUDE.md`**，该文件定义了编码准则、安全边界、构建命令和开发流程。如 AI 助手未自动读取该文件，请在提示词中明确要求模型先阅读 `CLAUDE.md`
- AI 生成的代码可能不符合项目既有风格，提交前请进行人工审查
- AI 无法替代对 macOS 系统行为的理解，涉及文件系统操作、代码签名、权限管理等逻辑时请务必手动验证
- **核心功能**（如迁移策略、数据目录迁移、代码签名等）的变更同样遵循上述讨论流程，获得确认后再执行开发。

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

**区分合并门槛与验证责任：** PR 的自动合并门槛仍是 Release 编译；外部贡献者建议运行受影响模块的测试，并在 PR 中如实记录通过、失败、跳过或未运行及原因。AI 助手还必须遵循 `CLAUDE.md`：修改已有测试覆盖的模块时运行对应测试。Advisory 表示 CI 不阻塞合并，不表示失败可以忽略；需要说明失败是否与本次改动有关。

完整测试在可弃置的 macOS runner 上执行；部分集成测试会注册临时应用到 Launch Services。不要用 `sudo` 运行测试，也不要在 CI 中设置 `APPPORTS_TEST_EXTERNAL_ROOT` 或 `APPPORTS_RENDER_UI_OUTPUT`。真实外置盘实验应使用专用测试数据，并与默认自动测试区分。

#### 按需运行：专项测试

当 PR 涉及对应模块时，建议主动补跑专项测试。CI 会在独立的 macOS runner 上运行完整 `AppPortsTests`：应用回归、进程计时、本地化审计分三步执行，共用一次 Debug 测试编译。计时测试单独运行，避免大量并发的迁移测试干扰超时断言。PR 中这些结果仍为 Advisory，不阻塞合并。

请查看 `Tests (Advisory)` 的步骤摘要：它会分别显示通过、失败、取消或未运行；任务显示绿色不代表所有 Advisory 测试通过。日志和 `.xcresult` 诊断产物保存 5 天。新提交会取消同一 PR 的旧检查。

| 测试套件 | 涉及模块 | 运行时机 |
|----------|----------|----------|
| `DataDirMoverTests` | 数据目录迁移 | 涉及 `DataDirMover` 时 |
| `DataDirScannerTests` | 数据目录扫描 | 涉及 `DataDirScanner` 时 |
| `AppMigrationServiceTests` | 应用迁移 | 涉及 `AppMigrationService` 时 |
| `AppScannerTests` | 应用扫描 | 涉及 `AppScanner` 时 |
| `AppLoggerTests` | 日志与诊断 | 涉及 `AppLogger` 时 |
| `LocalizationAuditTests` | 本地化 | 涉及用户可见文案时 |

其他改动的测试入口（并非完整清单，须结合调用方选择）：

| 改动领域 | 测试入口 |
| --- | --- |
| 自选目录 | `CustomDirScannerTests`、`CustomDirRecoveryEligibilityTests` |
| 文件复制与所有权 | `FileCopierTests`、`TreeCopySessionTests`、`TreeCopyOwnershipTests` |
| 容器挂载迁移 | `ContainerVolumeMigratorTests`、`ContainerMountSafetyTests` |
| 签名操作与修复 | `CodeSignerTests`、`SignatureOperationTests`、`SignatureRepairSafetyTests` |
| 迁移账本与恢复 | `DataTransferStoreTests`、`DataTransferRecoveryTests`、`AppTransferTransactionTests` |
| 操作状态与 Dock | `AppOperationStateTests`、`DockShortcutServiceTests` |
| 子进程期限 | `ProcessCommandRunnerTests`（单独运行） |
| 更新与赞助名单 | `UpdateCheckerTests`、`SponsorsTests` |

CI 的完整命令见[共用脚本](.github/scripts/run-xcode-check.sh)：`prepare-tests` 后依次运行 `regression`、`process`、`localization`，共用同一 runner 和 DerivedData；`release` 执行 Release clean build。调用前设置 `CI_DERIVED_DATA_PATH` 和 `CI_RESULTS_DIR` 为本次验证专用目录，重复运行使用新的结果目录，避免已有 `.xcresult` 冲突。修改共享复制、扫描或传输基础逻辑后，推进 `main` 前还须按 `CLAUDE.md` 完成隔离 runner 的完整验证。

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

- 全语言翻译可以在外部贡献者的 PR 中延后，但代码仍须正确接入本地化：新增 key 进入 `AppPorts/Localizable.xcstrings`，AppKit/API 文案使用 `.localized`，动态文案使用格式化 key，语言列表来自 `AppLanguageCatalog`。
- 未完成翻译时，在 PR 中列出受影响文案、语言、实际回退显示和后续计划；不要用复制英文、删除审计断言或扩大豁免名单来掩盖缺译。AI 助手按 `CLAUDE.md` 与维护者确认本次翻译范围。
- 字符串目录只修改相关 key 和译文，避免夹带整份目录重排。菜单、弹窗、设置、错误、状态和 onboarding 文案变更后，建议检查 `zh-Hans` 与 `en` 的实际显示。

- PR 仅强制编译烟雾检查；合并到 `main` 后，应用回归与进程计时测试必须通过，本地化审计仍为 Advisory。随后编译 Release 并校验、上传未签名应用包。

更多规则见：[LOCALIZATION.md](LOCALIZATION.md)

### 🛠️ 代码提交规范

- **重要功能先讨论**：重要功能的变更请先通过 [Issue](https://github.com/wzh4869/AppPorts/issues) 讨论，或者加入 [QQ群 (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) 向群主讨论；群内讨论后，由群主在 Issue 公示讨论结论。
- **保持原子化**：每个 PR 尽量只解决一个问题或添加一个功能。
- **清晰的注释**：为复杂的逻辑编写清晰的 Swift 文档注释。
- **Commit 信息建议**：
  - `feat: ...` (新功能)
  - `fix: ...` (修复 Bug)
  - `docs: ...` (文档更新)
  - `refactor: ...` (重构)
  - `test: ...` (测试相关)

### 决策笔记

非平凡改动（行为、架构、跨文件契约、流程工具、测试策略或存储格式）须随代码在同一 commit / PR 中提交决策笔记。先搜索 `.agents/notes/` 的现有决定；已有归属的事实更新原笔记，新的取舍按[仓库内技能](.claude/skills/write-notes-like-deepseek/SKILL.md)处理。纯机械改动免写。笔记只放 `.agents/notes/`，不放 `User_docs`；格式、生命周期和三项校验命令以该技能为准。PR 中附笔记链接，或说明不适用原因。

### 文档贡献与指南同步

仅修改文档站时，先阅读 [User_docs/README.md](User_docs/README.md) 和 [User_docs/AGENTS.md](User_docs/AGENTS.md)。在 `User_docs` 下使用兼容的 Node.js LTS，执行 `npm ci`、`npm run docs:dev`；编辑 Markdown 后运行 `npm run docs:prepare` 刷新。提交前依次执行 `npm run docs:build`、`npm run docs:typecheck`、`npm run docs:check`。

简中源文与繁中、英文译文须同步，共用章节 ID 及其顺序。不要编辑或提交 `.content/`、`public/`、`.next/`、`out/` 生成产物。检查修改页面的三语桌面及手机显示；涉及站点功能时，另查搜索、主题、语言切换和 Markdown 导出。纯文档贡献按文档检查验证；应用源码改动按应用构建和相关测试验证；应用翻译改动按本地化审计和显示检查验证。构建不会自动发布站点。

根目录 [CONTRIBUTING.md](CONTRIBUTING.md) 是贡献流程入口；修改共享规则时同步根目录中英文、文档站简中/繁中/英文指南和受影响的 PR 模板。AI 执行规则以 `AGENTS.md` / `CLAUDE.md` 为准，文档站操作细节以 `User_docs/README.md` 为准，笔记规范以仓库内技能为准。

### ❤️ 欢迎所有形式的贡献

我们特别欢迎：
- 针对 `AppScanner` 等核心逻辑的稳定性和性能改进。
- UI/UX 的优化，特别是符合 macOS 系统原生感的改进。
- 简体中文、繁体中文和英文文档的同步与完善。

---

## English

Thank you for your interest in **AppPorts**! We welcome community contributions, whether it's fixing bugs, improving documentation, or adding new features.

### 🚀 How to Start?

1.  **Feedback and discussion**: Search existing [Issues](https://github.com/wzh4869/AppPorts/issues) to avoid duplicates. Discuss significant feature changes in an [Issue](https://github.com/wzh4869/AppPorts/issues) first, or join the [QQ group (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) to discuss them with the group owner. After a group discussion, the group owner publishes the conclusions in an Issue.
2.  **Fork & Clone**: Fork the project to your account and clone it locally.
3.  **Create a Branch**: Create a feature branch (`feat/your-feature`) or a fix branch (`fix/your-fix`) based on the `main` branch.
4.  **Write Code**: Follow Swift coding conventions and the project's existing style.
5.  **Local Testing**: Run in Xcode and ensure all functions work correctly (see testing requirements below).
6.  **Submit a PR**: Push your branch to your repository and submit a Pull Request to the `main` branch of **AppPorts**.

### Development environment

- The app runs on macOS 12 or later; this is not the minimum development environment. Development needs full Xcode, not just Command Line Tools, and the test toolchain must support Swift Testing. Prefer the Xcode used by current CI; find its exact version in the Actions Build environment log. The repository does not yet declare a verified minimum Xcode version.
- Open `AppPorts.xcodeproj`, select the shared `AppPorts` scheme and My Mac. The app does not use Swift Package Manager or third-party Swift dependencies. The unsigned command-line checks below need no release certificate; grant permissions for the operations you exercise when running locally.
- Check the active toolchain with `xcodebuild -version`. If Xcode is outside the default location, set `DEVELOPER_DIR` in your terminal, for example:

```bash
export DEVELOPER_DIR="/Volumes/<external-volume>/Applications/Xcode.app/Contents/Developer"
```

### 🤖 About Vibe Coding

AppPorts accepts Vibe Coding with AI-assisted tools (e.g., Cursor, GitHub Copilot, Claude). **However, the quality and correctness of submitted code is the contributor's responsibility.**

- **AI assistants must follow the `CLAUDE.md` file in the project root.** It defines coding guidelines, safety boundaries, build commands, and development workflows. If the AI assistant does not read it automatically, explicitly instruct the model to read `CLAUDE.md` in your prompt.
- AI-generated code may not match the project's existing style — review it manually before committing
- AI cannot replace understanding of macOS system behavior — manually verify logic involving file system operations, code signing, and permission management
- **Core-feature changes**, including migration strategies, data migration, and code signing, follow the same discussion process and require confirmation before development.

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

**Separate merge gates from verification responsibilities:** the automated PR merge gate remains the Release build. External contributors are encouraged to run tests for affected modules and report passed, failed, skipped, or not-run checks and reasons in the PR. AI assistants must also follow `CLAUDE.md`: run the relevant tests when changing a module with existing coverage. Advisory means CI does not block merging; investigate and explain whether failures relate to the change.

Run the full suite on a disposable macOS runner; some integration tests register temporary apps with Launch Services. Do not run tests with `sudo` or set `APPPORTS_TEST_EXTERNAL_ROOT` or `APPPORTS_RENDER_UI_OUTPUT` in CI. Use dedicated test data for real external-drive experiments and distinguish them from default automated checks.

#### Recommended: Focused Tests

When a PR touches the relevant module, it is recommended to run focused tests. CI runs the full `AppPortsTests` target on a disposable macOS runner in three steps: app regression, process timing, and localization. They share one Debug test build. Timing tests run separately to avoid contention from process-heavy migration suites. All remain Advisory for PRs and do not block merging.

Read the `Tests (Advisory)` step summary for passed, failed, cancelled, or not-run results; a green advisory job does not mean every test passed. Logs and `.xcresult` diagnostic artifacts are retained for five days. A new commit cancels older checks for the same PR.

| Test Suite | Module | When to Run |
|------------|--------|-------------|
| `DataDirMoverTests` | Data directory migration | When touching `DataDirMover` |
| `DataDirScannerTests` | Data directory scanning | When touching `DataDirScanner` |
| `AppMigrationServiceTests` | App migration | When touching `AppMigrationService` |
| `AppScannerTests` | App scanning | When touching `AppScanner` |
| `AppLoggerTests` | Logging & diagnostics | When touching `AppLogger` |
| `LocalizationAuditTests` | Localization | When touching user-facing copy |

Other test entry points (not exhaustive; include affected callers):

| Change area | Test entry points |
| --- | --- |
| Custom folders | `CustomDirScannerTests`, `CustomDirRecoveryEligibilityTests` |
| File copying and ownership | `FileCopierTests`, `TreeCopySessionTests`, `TreeCopyOwnershipTests` |
| Container mount migration | `ContainerVolumeMigratorTests`, `ContainerMountSafetyTests` |
| Signing and repair | `CodeSignerTests`, `SignatureOperationTests`, `SignatureRepairSafetyTests` |
| Transfer records and recovery | `DataTransferStoreTests`, `DataTransferRecoveryTests`, `AppTransferTransactionTests` |
| Operation state and Dock | `AppOperationStateTests`, `DockShortcutServiceTests` |
| Subprocess deadlines | `ProcessCommandRunnerTests` (run separately) |
| Updates and sponsors | `UpdateCheckerTests`, `SponsorsTests` |

See the [shared CI script](.github/scripts/run-xcode-check.sh) for full commands: run `prepare-tests`, then `regression`, `process`, and `localization` on the same runner and DerivedData; `release` performs the Release clean build. Set `CI_DERIVED_DATA_PATH` and `CI_RESULTS_DIR` to dedicated validation directories before invoking it; use a fresh results directory on repeat runs to avoid existing `.xcresult` conflicts. Before advancing `main` after shared copy, scan, or transfer changes, also complete the full isolated-runner validation required by `CLAUDE.md`.

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

- External contributors may defer complete translations, but code must still use the localization system: add new keys to `AppPorts/Localizable.xcstrings`, use `.localized` for AppKit/API copy, format keys for dynamic text, and `AppLanguageCatalog` for the language list.
- If translations are deferred, list affected text, languages, actual fallback display, and follow-up plans in the PR. Do not hide missing translations by copying English, deleting audit assertions, or broadening exemptions. AI assistants confirm the translation scope with the maintainer as required by `CLAUDE.md`.
- Limit string-catalog edits to relevant keys and translations; avoid unrelated catalog reordering. For menu, dialog, settings, error, status, and onboarding changes, inspect the actual `zh-Hans` and `en` display where possible.

- Only the smoke build blocks PR merging. After merging to `main`, app regression and process timing tests must pass; localization remains advisory. CI then builds Release, validates the app bundle and ZIP, and uploads the unsigned app.

See [LOCALIZATION.md](LOCALIZATION.md) for the full workflow.

### 🛠️ Commit Guidelines

- **Discuss significant features first**: Discuss significant feature changes in an [Issue](https://github.com/wzh4869/AppPorts/issues) first, or join the [QQ group (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) to discuss them with the group owner. After a group discussion, the group owner publishes the conclusions in an Issue.
- **Keep it Atomic**: Try to keep each PR focused on a single issue or feature.
- **Clear Comments**: Write clear Swift documentation comments for complex logic.
- **Commit Message Suggestions**:
  - `feat: ...` (New feature)
  - `fix: ...` (Bug fix)
  - `docs: ...` (Documentation update)
  - `refactor: ...` (Refactoring)
  - `test: ...` (Testing)

### Decision notes

Non-trivial changes (behavior, architecture, cross-file contracts, process/tooling, test strategy, or storage formats) require a decision note in the same commit / PR as the code. Search existing decisions in `.agents/notes/` first; update facts in their owning note and follow the [vendored skill](.claude/skills/write-notes-like-deepseek/SKILL.md) for new tradeoffs. Mechanical edits are exempt. Keep notes only in `.agents/notes/`, not `User_docs`; the skill owns format, lifecycle, and the three validation commands. Link the note in the PR or explain why it is not applicable.

### Documentation contributions and guide synchronization

For documentation-site changes, first read [User_docs/README.md](User_docs/README.md) and [User_docs/AGENTS.md](User_docs/AGENTS.md). In `User_docs`, use a compatible Node.js LTS and run `npm ci` and `npm run docs:dev`; refresh edited Markdown with `npm run docs:prepare`. Before submitting, run `npm run docs:build`, `npm run docs:typecheck`, and `npm run docs:check` in that order.

Keep Simplified Chinese source, Traditional Chinese, and English translations synchronized, including chapter IDs and their order. Do not edit or commit generated `.content/`, `public/`, `.next/`, or `out/`. Inspect changed pages in all three languages on desktop and mobile; for site-function changes also check search, themes, language switching, and Markdown export. Validate documentation-only contributions with documentation checks, app-source changes with the app build and relevant tests, and app translations with localization auditing and display checks. Building does not publish the site.

The root [CONTRIBUTING.md](CONTRIBUTING.md) is the contribution-workflow entry point. When changing shared rules, synchronize its Chinese and English sections, the site's Simplified Chinese / Traditional Chinese / English guides, and affected PR-template fields. `AGENTS.md` / `CLAUDE.md` govern AI execution, `User_docs/README.md` owns site-operation details, and the vendored skill owns note conventions.

### ❤️ All Contributions are Welcome

We especially welcome:
- Stability and performance improvements for core logic like `AppScanner`.
- UI/UX optimizations, especially improvements that match the native macOS feel.
- Synchronization and improvement of Simplified Chinese, Traditional Chinese, and English documentation.

感谢你的每一份贡献！ | Thank you for every contribution!
