---
outline: deep
---

# 贡献者指南

感谢你关注 AppPorts！我们欢迎社区成员参与贡献，无论是修复 Bug、改进文档，还是添加新功能。

## 开始之前 {#section-1}

1. 搜索现有的 [Issues](https://github.com/wzh4869/AppPorts/issues)，确认没有相关的重复议题。
   重要功能的变更请先通过 [Issue](https://github.com/wzh4869/AppPorts/issues) 讨论，或者加入 [QQ群 (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) 向群主讨论；群内讨论后，由群主在 Issue 公示讨论结论。
2. Fork 项目并克隆到本地。
3. 基于 `main` 分支创建功能分支（`feat/your-feature`）或修复分支（`fix/your-fix`）。

- 应用运行支持 macOS 12 及以上；这不是开发环境的最低版本。开发需要完整 Xcode（仅安装 Command Line Tools 不够），测试工具链还须支持 Swift Testing。优先使用与当前 CI 一致的 Xcode；具体版本可从 Actions 的 Build environment 日志查看，仓库尚未声明经过验证的最低 Xcode 版本。
- 在 Xcode 中打开 `AppPorts.xcodeproj`，选择共享的 `AppPorts` scheme 和 My Mac。应用不使用 Swift Package Manager，也没有第三方 Swift 依赖。命令行验证使用下文的无签名参数，无需配置发布证书；本机运行时按实际操作授予所需权限。
- 先用 `xcodebuild -version` 检查当前工具链。Xcode 不在默认位置时，在当前终端设置 `DEVELOPER_DIR`，例如：

```bash
export DEVELOPER_DIR="/Volumes/<external-volume>/Applications/Xcode.app/Contents/Developer"
```

## 开发方式 {#section-2}

### 关于 Vibe Coding {#section-3}

AppPorts 项目接受使用 AI 辅助工具（如 Cursor、GitHub Copilot、Claude 等）进行 Vibe Coding 开发。AI 工具可以显著提高开发效率，**但提交代码的质量和正确性仍由贡献者本人负责**。

使用 Vibe Coding 时请注意：

- **AI 助手必须遵循项目根目录的 `CLAUDE.md`**。该文件定义了编码准则、安全边界、构建命令和开发流程。如 AI 助手未自动读取该文件，请在提示词中明确要求模型先阅读 `CLAUDE.md`。
- AI 生成的代码可能不符合项目既有风格，提交前请进行人工审查。
- AI 无法替代对 macOS 系统行为的理解。涉及文件系统操作、代码签名、权限管理等逻辑时，请务必手动验证。
- **核心功能**（如迁移策略、数据目录迁移、代码签名等）的变更同样遵循上述讨论流程，获得确认后再执行开发。

### 代码规范 {#section-4}

- 遵循 Swift 代码规范和项目既有风格。
- 为复杂逻辑编写清晰的 Swift 文档注释。
- SwiftUI 字面量使用 `LocalizedStringKey` API；AppKit/API 字符串使用 `.localized`。

## 测试要求 {#section-5}

::: warning PR 必须通过 Release 编译
CI 强制编译烟雾检查；专项测试提供 Advisory 反馈，不作为 PR 的自动合并门槛。
:::

**区分合并门槛与验证责任：** PR 的自动合并门槛仍是 Release 编译；外部贡献者建议运行受影响模块的测试，并在 PR 中如实记录通过、失败、跳过或未运行及原因。AI 助手还必须遵循 `CLAUDE.md`：修改已有测试覆盖的模块时运行对应测试。Advisory 表示 CI 不阻塞合并，不表示失败可以忽略；需要说明失败是否与本次改动有关。

完整测试在可弃置的 macOS runner 上执行；部分集成测试会注册临时应用到 Launch Services。不要用 `sudo` 运行测试，也不要在 CI 中设置 `APPPORTS_TEST_EXTERNAL_ROOT` 或 `APPPORTS_RENDER_UI_OUTPUT`。真实外置盘实验应使用专用测试数据，并与默认自动测试区分。

### 必须通过：编译烟雾检查 {#section-6}

所有 PR 必须通过 Xcode Release 编译，这是合并的硬性门槛：

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

### 按需运行：专项测试 {#section-7}

当 PR 涉及对应模块时，建议主动补跑以下专项测试。CI 也会在 PR 中以 Advisory 模式运行，结果不阻塞合并，但会提供反馈。

#### 数据目录测试 {#section-8}

当 PR 涉及 `DataDirMover`、`DataDirScanner` 或数据目录迁移相关逻辑时运行：

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

#### 应用迁移测试 {#section-9}

当 PR 涉及 `AppMigrationService`、`AppScanner` 或应用迁移逻辑时运行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppMigrationServiceTests" \
  -only-testing:"AppPortsTests/AppScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 日志测试 {#section-10}

当 PR 涉及 `AppLogger` 或诊断功能时运行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppLoggerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 本地化审计 {#section-11}

当 PR 涉及用户可见文案、菜单、弹窗、设置项、错误提示时运行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### 测试总览 {#section-12}

| 测试套件 | 涉及模块 | 运行时机 |
|----------|----------|----------|
| 编译烟雾检查 | 全项目 | **必须**（CI 强制） |
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

CI 在一次 Debug 测试编译后分应用回归、进程计时、本地化三步运行完整测试。PR 中均为 Advisory；合并到 `main` 后应用回归与进程计时必须通过，本地化仍为 Advisory，随后编译 Release 并校验、上传未签名应用包。绿色 Advisory 任务不保证全部测试通过，请阅读步骤摘要；日志与 `.xcresult` 保存 5 天。同一 PR 的新提交会取消旧检查。

CI 的完整命令见[共用脚本](https://github.com/wzh4869/AppPorts/blob/main/.github/scripts/run-xcode-check.sh)：`prepare-tests` 后依次运行 `regression`、`process`、`localization`，共用同一 runner 和 DerivedData；`release` 执行 Release clean build。调用前设置 `CI_DERIVED_DATA_PATH` 和 `CI_RESULTS_DIR` 为本次验证专用目录，重复运行使用新的结果目录，避免已有 `.xcresult` 冲突。修改共享复制、扫描或传输基础逻辑后，推进 `main` 前还须按 `CLAUDE.md` 完成隔离 runner 的完整验证。

## 本地化 {#section-13}

- 全语言翻译可以在外部贡献者的 PR 中延后，但代码仍须正确接入本地化：新增 key 进入 `AppPorts/Localizable.xcstrings`，AppKit/API 文案使用 `.localized`，动态文案使用格式化 key，语言列表来自 `AppLanguageCatalog`。
- 未完成翻译时，在 PR 中列出受影响文案、语言、实际回退显示和后续计划；不要用复制英文、删除审计断言或扩大豁免名单来掩盖缺译。AI 助手按 `CLAUDE.md` 与维护者确认本次翻译范围。
- 字符串目录只修改相关 key 和译文，避免夹带整份目录重排。菜单、弹窗、设置、错误、状态和 onboarding 文案变更后，建议检查 `zh-Hans` 与 `en` 的实际显示。

更多规则见：[LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Commit 规范 {#section-14}

- 重要功能的变更请先通过 [Issue](https://github.com/wzh4869/AppPorts/issues) 讨论，或者加入 [QQ群 (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) 向群主讨论；群内讨论后，由群主在 Issue 公示讨论结论。
- **保持原子化**：每个 PR 尽量只解决一个问题或添加一个功能
- **Commit 信息建议**：
  - `feat: ...` — 新功能
  - `fix: ...` — 修复 Bug
  - `docs: ...` — 文档更新
  - `refactor: ...` — 重构
  - `test: ...` — 测试相关

**决策笔记：** 非平凡改动（行为、架构、跨文件契约、流程工具、测试策略或存储格式）须随代码在同一 commit / PR 中提交决策笔记。先搜索 `.agents/notes/` 的现有决定；已有归属的事实更新原笔记，新的取舍按[仓库内技能](https://github.com/wzh4869/AppPorts/blob/main/.claude/skills/write-notes-like-deepseek/SKILL.md)处理。纯机械改动免写。笔记只放 `.agents/notes/`，不放 `User_docs`；格式、生命周期和三项校验命令以该技能为准。PR 中附笔记链接，或说明不适用原因。

## 提交 PR {#section-15}

1. 确保分支基于最新的 `main` 分支。
2. 推送到你的 Fork 仓库。
3. 向 AppPorts 的 `main` 分支提交 Pull Request。
4. 填写 PR 模板中的必填项。
5. 等待 CI 检查通过和 Code Review。

::: tip 提高合并效率
- 保持每个 PR 聚焦于单一问题或功能。
- 如实填写 PR 模板中的测试情况。
- 涉及 UI 变更时附上截图。
:::

根目录 [CONTRIBUTING.md](https://github.com/wzh4869/AppPorts/blob/main/CONTRIBUTING.md) 是贡献流程入口；修改共享规则时同步根目录中英文、文档站简中/繁中/英文指南和受影响的 PR 模板。AI 执行规则以 `AGENTS.md` / `CLAUDE.md` 为准，文档站操作细节以 `User_docs/README.md` 为准，笔记规范以仓库内技能为准。

## 欢迎的贡献方向 {#section-16}

- 针对 `AppScanner` 等核心逻辑的稳定性和性能改进。
- UI/UX 优化，特别是符合 macOS 系统原生体验的改进。
- 简体中文、繁体中文和英文文档的同步与完善。

仅修改文档站时，先阅读 [User_docs/README.md](https://github.com/wzh4869/AppPorts/blob/main/User_docs/README.md) 和 [User_docs/AGENTS.md](https://github.com/wzh4869/AppPorts/blob/main/User_docs/AGENTS.md)。在 `User_docs` 下使用兼容的 Node.js LTS，执行 `npm ci`、`npm run docs:dev`；编辑 Markdown 后运行 `npm run docs:prepare` 刷新。提交前依次执行 `npm run docs:build`、`npm run docs:typecheck`、`npm run docs:check`。

简中源文与繁中、英文译文须同步，共用章节 ID 及其顺序。不要编辑或提交 `.content/`、`public/`、`.next/`、`out/` 生成产物。检查修改页面的三语桌面及手机显示；涉及站点功能时，另查搜索、主题、语言切换和 Markdown 导出。纯文档贡献按文档检查验证；应用源码改动按应用构建和相关测试验证；应用翻译改动按本地化审计和显示检查验证。构建不会自动发布站点。
