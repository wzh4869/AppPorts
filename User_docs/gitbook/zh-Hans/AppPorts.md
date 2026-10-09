---
icon: "compass"
layout:
  width: "default"
  outline:
    visible: true
---

# AppPorts 用户指南

本指南系统介绍 AppPorts 的核心功能、设计原则与技术实现。更多技术细节可参阅 [DeepWiki](https://deepwiki.com/wzh4869/AppPorts)。如有改进建议，欢迎在项目 [Issues](https://github.com/wzh4869/AppPorts/issues) 中反馈。

## 概述 <a href="#概述" id="概述"></a>

AppPorts 是专为 [macOS](https://www.apple.com.cn/os/macos/) 设计的应用迁移与链接工具。它可以将大型应用迁移到外部存储设备，并尽量保持 Finder、Launchpad、应用菜单和系统更新行为的一致性。

### AppPorts 哲学 <a href="#appports-哲学" id="appports-哲学"></a>

| 原则 | 说明 |
|------|------|
| **透明体验** | 尽量让用户和操作系统都像使用本地应用一样使用已迁移应用 |
| **策略稳定** | 优先采用经过验证、迁移稳定性更高的方案 |
| **低系统负担** | 不依赖守护进程，避免持续占用系统资源 |
| **广泛国际化** | 优先覆盖更多语言，持续改进翻译质量 |
| **无障碍友好** | 提供较完整的无障碍访问支持 |

## 核心功能 <a href="#核心功能" id="核心功能"></a>

- **无角标迁移**：一键将大型应用迁移至外部存储。本地仅保留轻量启动器壳，Finder 不显示快捷方式箭头，Launchpad 与 macOS 应用菜单正常显示。
- **自动更新保护**：自动识别支持自更新的应用（Sparkle、Electron、Chrome 等），提供「锁定迁移」选项，防止外部存储上的应用被自动更新程序删除或覆盖。
- **版本同步提示**：当本地真实应用版本高于外部存储中的旧副本时，标记为「待迁出」，提示可将本地新版迁出并替换外部旧版本。
- **Stub Portal 版本同步**：外置硬盘上的应用通过 App Store 更新后，本地 Stub Portal 的版本信息会自动同步，「打开方式」菜单始终显示正确版本。
- **自定义扫描目录**：支持添加额外的本地应用扫描目录（如 JetBrains Toolbox、Steam 等），自动保存并监控变化。
- **代码签名管理**：应用本体迁移后如出现「已损坏」提示，可通过右键菜单重签名，支持备份与恢复原始签名。沙盒应用一律不重签名。
- **macOS 15.1+ App Store 支持**：支持将 App Store 应用直接安装至外部存储，并在外部存储上原地更新，无需迁回本地。
- **一键还原**：支持将应用迁回本地并自动移除链接。迁移中断时可自动恢复。
- **数据目录管理**：支持将应用数据目录（`~/Library/` 子目录、`~/.npm` 等）迁移至外部存储，提供树形分组视图、搜索与排序功能，并通过 AppPorts metadata 严格校验恢复目标。
- **容器数据挂载迁移**：微信聊天记录等沙盒容器数据通过在 APFS 外置盘上创建独立卷并挂载到原目录的方式迁移，应用签名不做任何修改。
- **目录迁移**：支持将用户目录下的任意真实文件夹迁移到外部存储，适合大型项目、模型、素材库和工具缓存，并提供接回、还原和路径重叠校验。


## 迁移策略 <a href="#迁移策略" id="迁移策略"></a>

### Deep Contents Wrapper（Contents 目录迁移） <a href="#deep-contents-wrapper-contents-目录迁移" id="deep-contents-wrapper-contents-目录迁移"></a>

macOS 应用的标准文件结构如下：

```text
/Applications/Safari.app/
├── Contents/
│   ├── MacOS/
│   ├── Resources/
│   ├── Frameworks/
│   └── Info.plist
└── ...
```

Deep Contents Wrapper 策略会将应用的全部内容迁移至外部存储，并在本地创建同名的空 `.app` 目录，其中仅包含指向外部存储 `Contents` 目录的符号链接。由于 macOS 检测到的是一个完整的 `.app` 包（而非快捷方式），Finder 不会显示箭头标记，图标、Launchpad 与应用菜单均可正常工作。

{% hint style="warning" %}
**此策略已在当前版本中弃用**

Deep Contents Wrapper 的主要缺陷在于：自动更新程序运行时可能沿符号链接直接操作外部存储上的文件，从而破坏应用本体。
{% endhint %}

### Stub Portal（壳门方案） <a href="#stub-portal-壳门方案" id="stub-portal-壳门方案"></a>

Stub Portal 方案在本地创建一个最小化的 `.app` 壳，仅包含以下四项内容：

| 组件 | 说明 |
|------|------|
| `Contents/MacOS/launcher` | 启动器，执行 `open "/Volumes/External/SomeApp.app"` |
| `Contents/Resources/` | 从外部应用复制的图标文件 |
| `Contents/Info.plist` | 基于外部应用的 `Info.plist` 精简生成，将 `CFBundleExecutable` 设为 `launcher`，添加 `LSUIElement=true`（不在 Dock 显示），移除所有更新相关配置键 |
| `Contents/PkgInfo` | 标准的 4 字节标识文件 |

用户点击此壳时，macOS 会执行 `launcher`，并通过 `open` 命令启动外部存储上的真实应用。本地不包含符号链接，因此自动更新程序无法沿链接穿透到外部应用。

### iOS Stub Portal（iOS 壳门方案） <a href="#ios-stub-portal-ios-壳门方案" id="ios-stub-portal-ios-壳门方案"></a>

基本原理与标准 Stub Portal 一致，但图标处理方式不同。iOS 应用的图标不在 `Info.plist` 中指定，而是存储在 `Wrapper/` 或 `WrappedBundle/` 目录下的多个 `AppIcon.png` 文件中。处理流程如下：

1. 查找分辨率最大的 `AppIcon.png` 文件
2. 使用 `sips` 缩放至 256×256 像素
3. 使用 `sips` 转换为 `.icns` 格式
4. 基于 `iTunesMetadata.plist` 生成 `Info.plist`（iOS 应用不包含标准 `Info.plist`）

### Whole Symlink（整体符号链接） <a href="#whole-symlink-整体符号链接" id="whole-symlink-整体符号链接"></a>

将整个 `.app` 目录创建为指向外部存储的符号链接：

```text
/Applications/SomeApp.app → /Volumes/External/SomeApp.app
```

本地仅保留一个符号链接，不包含实际应用文件。macOS 通常可以正常打开应用，但 Finder 会在图标上显示快捷方式箭头，Launchpad 也可能出现兼容性问题。此外，自动更新程序同样可能沿符号链接操作外部存储上的应用文件。因此，该方式主要作为 AppPorts 的保底迁移策略。
