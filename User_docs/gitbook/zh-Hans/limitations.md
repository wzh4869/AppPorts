---
icon: "triangle-exclamation"
layout:
  width: "default"
  outline:
    visible: true
---

# 兼容性与限制

## 系统要求 <a href="#系统要求" id="系统要求"></a>

| 要求 | 说明 |
|------|------|
| 最低系统版本 | macOS 12.0 (Monterey) |
| 架构 | Intel x86_64 / Apple Silicon (arm64) |
| 权限 | 完全磁盘访问权限 |
| 外部存储 | 需要至少一个外部存储设备 |

## 功能兼容性 <a href="#功能兼容性" id="功能兼容性"></a>

### 按 macOS 版本 <a href="#按-macos-版本" id="按-macos-版本"></a>

| 功能 | macOS 12.0 - 15.0 | macOS 15.1+ |
|------|:---:|:---:|
| 应用迁移（Stub Portal） | ✓ | ✓ |
| 数据目录迁移（符号链接） | ✓ | ✓ |
| 容器数据挂载迁移 | ✓（挂载需输入管理员密码） | ✓（27 实测无需密码；13 至 26 未逐一验证） |
| 目录迁移（自定义文件夹） | ✓ | ✓ |
| 代码签名管理 | ✓ | ✓ |
| App Store 应用迁移到外部存储 | ✗ | ✓ |
| App Store 应用在外部存储原地更新 | ✗ | ✓ |
| iOS 应用迁移 | ✓ | ✓ |

{% hint style="warning" %}
**macOS 15.1 以下的 App Store 应用**

macOS 15.1（Sequoia）之前的系统不支持 App Store 应用原生安装到外部存储。若确需迁移，需要在 AppPorts 设置中手动开启「App Store 应用迁移」开关；应用更新后，也需要再次手动迁移以覆盖外部副本。
{% endhint %}

### 按应用类型 <a href="#按应用类型" id="按应用类型"></a>

| 应用类型 | 迁移 | 还原 | 自动更新 | 说明 |
|----------|:---:|:---:|:---:|------|
| 原生 macOS 应用 | ✓ | ✓ | ✓ | 最佳兼容性 |
| Sparkle 应用 | ✓ | ✓ | 需锁定 | 锁定后会阻止应用内更新，需迁回本地后更新 |
| Electron 应用 | ✓ | ✓ | 需锁定 | 与 Sparkle 应用相同 |
| Chrome / Edge（自定义更新器） | ✓ | ✓ | ✓ | 更新程序安装到本地，不破坏外部副本 |
| App Store 应用（macOS 15.1+） | ✓ | ✓ | ✓ | 原生外置安装，App Store 可直接更新 |
| App Store 应用（macOS <15.1） | ✓ | ✓ | 需手动 | 更新后需再次迁移 |
| iOS 应用（Mac 版） | ✓ | ✓ | ✓ | 使用 iOS Stub Portal |
| 系统应用 | ✗ | — | — | SIP 保护，不可迁移 |

{% hint style="warning" %}
**受保护应用迁移**

App Store 应用或 root 所有的应用可能因 macOS 权限无法由 AppPorts 自动删除或替换本地副本。出现受保护应用提示时，建议先在 Finder 中手动移动到外部存储，再回到 AppPorts 创建本地链接。
{% endhint %}

{% hint style="success" %}
**关于 Finder 快捷方式箭头**

旧版 AppPorts 创建的迁移入口可能使用整体符号链接，因此 Finder 会显示快捷方式箭头。当前版本对普通 `.app` 应用默认使用 Stub Portal，本地入口通常不会显示箭头；如仍看到箭头，建议迁回本地后重新迁移。
{% endhint %}

{% hint style="success" %}
**关于「待迁出」**

「待迁出」依赖可比较的应用版本和可靠的同一应用判断。AppPorts 会优先使用 Bundle ID 匹配本地与外部应用，并在必要时按规范化应用名称兜底；如果版本号缺失、格式无法比较，或同名应用 Bundle ID 不一致，就不会显示该状态。
{% endhint %}

### 按数据目录类型 <a href="#按数据目录类型" id="按数据目录类型"></a>

| 数据目录类型 | 迁移方式 | 风险 |
|-------------|:---:|------|
| `~/Library/Application Support/` | 符号链接 | 中 — 应用可能使用文件锁或 SQLite WAL 日志 |
| `~/Library/Preferences/` | 符号链接 | 低-中 — `cfprefsd` 缓存可能导致读取到过期配置 |
| `~/Library/Containers/` | 挂载 | 中 — 需要未加密的 APFS 外置盘；首次打开应用需允许授权框；打开前先插盘 |
| `~/Library/Group Containers/` | 挂载 | 中 — 同上；共享数据会影响同一 Team 下的其他应用 |
| `~/Library/Caches/` | 符号链接 | 低 — 缓存可重建 |
| `~/Library/Logs/` | 符号链接 | 低 — 仅日志文件 |
| `~/Library/WebKit/` | 符号链接 | 中 — WebKit 本地存储 |
| `~/Library/HTTPStorages/` | 符号链接 | 低 — 网络会话存储 |
| `~/Library/Application Scripts/` | 符号链接 | 低 — 扩展脚本 |
| `~/Library/Saved Application State/` | 符号链接 | 低 — 窗口状态恢复 |
| `~/.npm`、`~/.m2` 等 dot-folder | 符号链接 | 低 — 开发工具缓存 |
| 用户主目录下的自定义文件夹 | 符号链接 | 视内容而定 — 迁移前应关闭正在写入的应用或工具 |

{% hint style="warning" %}
**高价值数据目录**

微信聊天记录、虚拟机镜像、游戏库、数据库、模型缓存等目录通常体积大、写入频繁，且对路径和文件锁较敏感。迁移前建议先做独立备份；迁移后如应用提示数据异常，应优先恢复到本地再排查。
{% endhint %}

{% hint style="warning" %}
**容器数据只能挂载迁移**

`~/Library/Containers/` 与 `~/Library/Group Containers/` 里的数据用符号链接搬走后沙盒应用读不到；旧版本靠重签名绕过，代价是应用在 macOS 27 上可能无法打开。1.9.0 起这两类目录只提供[挂载迁移](datamigrae/mount-migration.md)，并对沙盒应用一律拒绝重签名。来龙去脉见[容器数据、沙盒与签名身份](datamigrae/container-identity.md)。
{% endhint %}

{% hint style="warning" %}
**自定义目录范围**

目录迁移面向用户主目录中的真实文件夹；不能选择文件、符号链接、外部目标内部路径、系统目录，或与已管理项目互相包含的路径。
{% endhint %}

{% hint style="warning" %}
**目标目录冲突**

数据目录迁移不会因为外部目录大小接近就自动接管或恢复。只有外部目录中的 AppPorts metadata 与当前任务完整匹配时，AppPorts 才会继续自动恢复；否则会将其视为真实目录冲突并停止操作。
{% endhint %}

## 不可迁移的内容 <a href="#不可迁移的内容" id="不可迁移的内容"></a>

### 受 SIP 保护 <a href="#受-sip-保护" id="受-sip-保护"></a>

| 路径 | 原因 |
|------|------|
| macOS 系统应用（Safari、Finder 等） | 系统完整性保护 |
| `~/Library/Containers/` 顶层目录 | macOS 系统保护 |

### 包含路径引用 <a href="#包含路径引用" id="包含路径引用"></a>

| 路径 | 原因 |
|------|------|
| `~/.local` | 包含可执行文件路径引用，迁移后命令行工具可能失效 |
| `~/.config` | 包含绝对路径配置，迁移后工具配置可能失效 |

## 外部存储要求 <a href="#外部存储要求" id="外部存储要求"></a>

| 要求 | 说明 |
|------|------|
| 文件系统 | 应用本体和普通数据目录：APFS、HFS+、exFAT 均可。**容器数据：仅 APFS** |
| 最小空间 | 视迁移应用大小而定 |
| 接口 | USB、Thunderbolt、NVMe 均支持 |
| 保持连接 | 迁移后外部存储需保持连接，否则相关应用无法启动 |

{% hint style="success" %}
**文件系统建议**

- **APFS**：推荐。唯一支持容器数据挂载迁移的格式，性能也最好
- **HFS+**：兼容旧款 Mac，不能迁移容器数据
- **exFAT**：跨平台，不能迁移容器数据；要和 Windows 共用时可以使用独立的 APFS 分区。若 exFAT 占满整块盘，系统自带工具不能直接缩小它，需先备份再重新分区；已有未分配空间时可按[分区条件](why-apfs.md#prepare-apfs)新建 APFS 分区

为什么容器数据只能用 APFS，以及我们试过的替代方案，见[为什么外置盘必须是 APFS](why-apfs.md)。
{% endhint %}

### 网络挂载盘 <a href="#网络挂载盘" id="网络挂载盘"></a>

NAS、SMB、rclone、SFTP 等网络挂载盘不属于 AppPorts 的主要验证目标。它们可能可以使用，但需要自行确认挂载稳定性、路径一致性、权限、扩展属性和符号链接行为。对于需要持续写入的数据目录，不建议优先使用网络挂载盘。
