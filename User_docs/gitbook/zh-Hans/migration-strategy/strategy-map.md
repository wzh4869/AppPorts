---
icon: "table-list"
description: "按应用类型查找对应的迁移策略。"
layout:
  width: "default"
  outline:
    visible: true
---

# 应用类型与策略对照

| 应用类型 | 容器分类 | 迁移策略 | 锁定保护 | 说明 |
|----------|----------|----------|----------|------|
| 原生 macOS 应用（无自更新） | `standaloneApp` | macOS Stub Portal | 否 | 如 Safari、Finder |
| Sparkle 自更新应用 | `standaloneApp` | macOS Stub Portal | **是** | 如部分独立开发者应用 |
| Electron 应用（无 `app-update.yml`） | `standaloneApp` | macOS Stub Portal | 否 | 如 VS Code |
| Electron 应用（有 `app-update.yml`） | `standaloneApp` | macOS Stub Portal | **是** | 如 Slack、Discord |
| Electron + Sparkle 混合应用 | `standaloneApp` | macOS Stub Portal | **是** | 两个标志独立检测，同时成立 |
| 自定义更新器应用（Chrome、Edge） | `standaloneApp` | macOS Stub Portal | 否 | 通过 `LaunchServices`、`KSProductID` 等识别 |
| iOS 应用（Mac 版） | `standaloneApp` | iOS Stub Portal | 否 | 图标从 `WrappedBundle` 提取，不签名 |
| Mac App Store 应用 | `standaloneApp` | macOS Stub Portal | 否 | SIP 保护，无法重签名 |
| 单应用容器目录 | `singleAppContainer` | Whole App Symlink | 否 | 目录内仅 1 个 `.app`，整体符号链接 |
| 应用套件目录（如 Office） | `appSuiteFolder` | Whole App Symlink | 视内部应用而定 | 目录内 2+ 个 `.app`，整体符号链接 |
| 非 `.app` 路径 | — | Whole App Symlink | — | 扩展名不为 `.app` 的路径 |

{% hint style="warning" %}
**关于锁定保护**

当应用被标记为需要锁定（`needsLock = true`）时，AppPorts 在迁移完成后对外部存储上的应用执行 `chflags -R uchg`，设置不可变标志。这会阻止自更新程序删除或修改外部副本，但也意味着应用无法自行更新。用户需要在 AppPorts 中手动解锁后才能进行更新。
{% endhint %}

{% hint style="success" %}
**自定义更新器应用为何不锁定**

Chrome、Edge 等使用自定义更新器的应用不会被锁定。这类应用的更新程序通常会将新版本下载并安装到本地内部存储，受到 macOS Stub Portal 的链接隔离特性，因此不会破坏外部存储上的应用文件。

当 AppPorts 检测到本地内部存储上的应用版本高于外部存储上的版本时，会自动为该应用打上「待迁出」标签，提示用户需要重新迁移以同步最新版本。
{% endhint %}
