# 自更新应用识别

## Electron 应用识别 <a href="#electron-应用识别" id="electron-应用识别"></a>

AppPorts 通过以下三个条件识别 Electron 应用。检测会按优先级依次执行，并采用短路求值：

| # | 检测项 | 路径 / 模式 |
|---|--------|-------------|
| 1 | Electron Framework | `Contents/Frameworks/Electron Framework.framework` 目录存在 |
| 2 | Electron Helper 变体 | `Contents/Frameworks/` 下存在名称包含 `Electron Helper` 的条目 |
| 3 | Info.plist 标识键 | `Contents/Info.plist` 中存在 `ElectronDefaultApp` 或 `electron` 键 |

### Electron 自更新检测 <a href="#electron-自更新检测" id="electron-自更新检测"></a>

在识别为 Electron 应用后，AppPorts 还会检查是否存在 `Contents/Resources/app-update.yml` 文件。该文件是 `electron-updater` 的配置文件；若存在，则标记该 Electron 应用具有自更新能力。

## Sparkle 应用识别 <a href="#sparkle-应用识别" id="sparkle-应用识别"></a>

AppPorts 通过以下三个条件识别 Sparkle 应用：

| # | 检测项 | 路径 / 模式 |
|---|--------|-------------|
| 1 | Sparkle 框架 | `Contents/Frameworks/Sparkle.framework` 或 `Contents/Frameworks/Squirrel.framework` 存在 |
| 2 | 更新器二进制文件 | `Contents/MacOS/` 或 `Contents/Frameworks/` 下存在匹配 `shipit`、`autoupdate`、`updater`、`update` 的文件 |
| 3 | Info.plist Sparkle 键 | `Contents/Info.plist` 中存在以下任一键：`SUFeedURL`、`SUPublicDSAKeyFile`、`SUPublicEDKey`、`SUScheduledCheckInterval`、`SUAllowsAutomaticUpdates` |

{% hint style="warning" %}
**Electron 应用的特殊处理**

当应用已被识别为 Electron 应用时，检测条件 #2（更新器二进制文件）会被跳过，以避免 `electron-updater` 的 `updater` 二进制文件导致误判为 Sparkle 应用。
{% endhint %}

## 混合 Electron + Sparkle 应用 <a href="#混合-electron-sparkle-应用" id="混合-electron-sparkle-应用"></a>

部分应用同时包含 Electron 框架和 Sparkle 更新器。AppPorts 对两个标志独立检测，允许 `isElectron` 和 `isSparkle` 同时为 `true`。

### 检测逻辑 <a href="#检测逻辑" id="检测逻辑"></a>

```text
isElectron = 满足 Electron 三个检测条件之一
isSparkle  = 满足 Sparkle 三个检测条件之一（Electron 应用跳过条件 #2）
```

两个标志互不影响，因此可以同时成立。

### 迁移后行为 <a href="#迁移后行为" id="迁移后行为"></a>

| 属性 | 判定条件 |
|------|----------|
| `hasSelfUpdater` | `isSparkle`，或（`isElectron` 且存在 `app-update.yml`），或存在自定义更新器 |
| `needsLock` | `isSparkle` 或 (`isElectron` 且存在 `app-update.yml`) |

当 `needsLock` 为 `true` 时，AppPorts 在迁移完成后对外部存储上的应用执行 `chflags -R uchg`（设置不可变标志），防止自更新程序删除或修改外部副本。

## 自定义更新器检测 <a href="#自定义更新器检测" id="自定义更新器检测"></a>

对于非 Sparkle、非 Electron 的原生自更新应用（如 Chrome、Edge、Parallels），AppPorts 通过以下模式进行识别：

| 检测路径 | 匹配模式 | 典型应用 |
|----------|----------|----------|
| `Contents/Library/LaunchServices/` | 文件名包含 `update` | Chrome、Edge、Thunderbird |
| `Contents/MacOS/` | 二进制文件名包含 `update` 或 `upgrade`（排除 `electron`） | Parallels、Thunderbird |
| `Contents/SharedSupport/` | 文件名包含 `update` | WPS Office |
| `Contents/Info.plist` | 存在 `KSProductID` 键 | Google Keystone（Chrome） |

## 遗留策略识别 <a href="#遗留策略识别" id="遗留策略识别"></a>

在还原或解除链接时，AppPorts 需要识别旧版本创建的遗留本地入口：

| 本地结构特征 | 识别为 |
|-------------|--------|
| 根路径为符号链接 | `wholeAppSymlink` |
| `Contents/` 为符号链接 | `deepContentsWrapper` |
| `Contents/Info.plist` 为符号链接 | `wholeAppSymlink`（遗留 Sparkle 混合方案） |
| `Contents/Frameworks/` 为符号链接 | `wholeAppSymlink`（遗留 Electron 混合方案） |
| `Contents/MacOS/launcher` 存在 | `stubPortal` |
| 以上均不匹配 | 非 AppPorts 管理的应用 |
