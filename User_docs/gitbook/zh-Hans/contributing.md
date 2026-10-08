# 贡献者指南

感谢你关注 AppPorts！我们欢迎社区成员参与贡献，无论是修复 Bug、改进文档，还是添加新功能。

## 开始之前 <a href="#开始之前" id="开始之前"></a>

1. 搜索现有的 [Issues](https://github.com/wzh4869/AppPorts/issues)，确认没有相关的重复议题。
2. Fork 项目并克隆到本地。
3. 基于 `develop` 分支创建功能分支（`feat/your-feature`）或修复分支（`fix/your-fix`）。

## 开发方式 <a href="#开发方式" id="开发方式"></a>

### 关于 Vibe Coding <a href="#关于-vibe-coding" id="关于-vibe-coding"></a>

AppPorts 项目接受使用 AI 辅助工具（如 Cursor、GitHub Copilot、Claude 等）进行 Vibe Coding 开发。AI 工具可以显著提高开发效率，**但提交代码的质量和正确性仍由贡献者本人负责**。

使用 Vibe Coding 时请注意：

- **AI 助手必须遵循项目根目录的 `CLAUDE.md`**。该文件定义了编码准则、架构规范、构建命令和开发流程。如 AI 助手未自动读取该文件，请在提示词中明确要求模型先阅读 `CLAUDE.md`。
- 建议通过多个 AI 模型交叉验证生成代码的质量与安全性，避免单一模型的盲区。
- AI 生成的代码可能不符合项目既有风格，提交前请进行人工审查。
- AI 无法替代对 macOS 系统行为的理解。涉及文件系统操作、代码签名、权限管理等逻辑时，请务必手动验证。
- **核心功能**（如迁移策略、数据目录迁移、代码签名等）的变更必须先提交 Issue 讨论，获得确认后再执行开发。

### 代码规范 <a href="#代码规范" id="代码规范"></a>

- 遵循 Swift 代码规范和项目既有风格。
- 为复杂逻辑编写清晰的 Swift 文档注释。
- SwiftUI 字面量使用 `LocalizedStringKey` API；AppKit/API 字符串使用 `.localized`。

## 测试要求 <a href="#测试要求" id="测试要求"></a>

{% hint style="warning" %}
**所有 PR 必须通过测试**

无论使用何种开发方式，提交 PR 前必须完成以下测试。CI 会自动运行编译烟雾检查，未通过的 PR 将被阻止合并。
{% endhint %}

### 必须通过：编译烟雾检查 <a href="#必须通过-编译烟雾检查" id="必须通过-编译烟雾检查"></a>

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

### 按需运行：专项测试 <a href="#按需运行-专项测试" id="按需运行-专项测试"></a>

当 PR 涉及对应模块时，建议主动补跑以下专项测试。CI 也会在 PR 中以 Advisory 模式运行，结果不阻塞合并，但会提供反馈。

#### 数据目录测试 <a href="#数据目录测试" id="数据目录测试"></a>

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

#### 应用迁移测试 <a href="#应用迁移测试" id="应用迁移测试"></a>

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

#### 日志测试 <a href="#日志测试" id="日志测试"></a>

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

#### 本地化审计 <a href="#本地化审计" id="本地化审计"></a>

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

### 测试总览 <a href="#测试总览" id="测试总览"></a>

| 测试套件 | 涉及模块 | 运行时机 |
|----------|----------|----------|
| 编译烟雾检查 | 全项目 | **必须**（CI 强制） |
| `DataDirMoverTests` | 数据目录迁移 | 涉及 `DataDirMover` 时 |
| `DataDirScannerTests` | 数据目录扫描 | 涉及 `DataDirScanner` 时 |
| `AppMigrationServiceTests` | 应用迁移 | 涉及 `AppMigrationService` 时 |
| `AppScannerTests` | 应用扫描 | 涉及 `AppScanner` 时 |
| `AppLoggerTests` | 日志与诊断 | 涉及 `AppLogger` 时 |
| `LocalizationAuditTests` | 本地化 | 涉及用户可见文案时 |

## 本地化 <a href="#本地化" id="本地化"></a>

- 本地化适配是推荐项，不作为外部贡献者提交 PR 的强制门槛。
- 如 PR 新增、修改或删除了用户可见文案，欢迎在同一个 PR 中同步更新 `Localizable.xcstrings`。
- 如本次暂不处理，请在 PR 说明中简要说明原因或后续计划。
- SwiftUI 字面量使用 `LocalizedStringKey` API；AppKit/API 字符串使用 `.localized`。
- 动态文案建议使用格式化 key，如 `String(format: "排序：%@".localized, value)`。
- 语言列表统一维护在 `AppLanguageCatalog`，不要在多个页面重复硬编码。
- 如 PR 变更了菜单、弹窗、设置项、日志导出、错误提示、状态文案或 onboarding 文案，建议至少检查一次 `zh-Hans` 和 `en` 的实际显示结果。

更多规则见：[LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Commit 规范 <a href="#commit-规范" id="commit-规范"></a>

- **Issue 优先**：重要功能的变更请先通过 Issue 讨论
- **保持原子化**：每个 PR 尽量只解决一个问题或添加一个功能
- **Commit 信息建议**：
  - `feat: ...` — 新功能
  - `fix: ...` — 修复 Bug
  - `docs: ...` — 文档更新
  - `refactor: ...` — 重构
  - `test: ...` — 测试相关

## 提交 PR <a href="#提交-pr" id="提交-pr"></a>

1. 确保分支基于最新的 `develop` 分支。
2. 推送到你的 Fork 仓库。
3. 向 AppPorts 的 `develop` 分支提交 Pull Request。
4. 填写 PR 模板中的必填项。
5. 等待 CI 检查通过和 Code Review。

{% hint style="success" %}
**提高合并效率**

- 保持每个 PR 聚焦于单一问题或功能。
- 如实填写 PR 模板中的测试情况。
- 涉及 UI 变更时附上截图。
{% endhint %}

## 欢迎的贡献方向 <a href="#欢迎的贡献方向" id="欢迎的贡献方向"></a>

- 针对 `AppScanner` 等核心逻辑的稳定性和性能改进。
- UI/UX 优化，特别是符合 macOS 系统原生体验的改进。
- 中英文档的同步和完善。
