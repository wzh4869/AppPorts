<div align="center">

# 📦 AppPorts

**外置硬盘拯救世界！/ External drives save the world!**

一款专为 macOS 设计的应用程序迁移与链接工具。
轻松将庞大的应用程序迁移至外部存储，同时保持系统无感运行。

[English](README.md)｜[简体中文](README_CN.md)｜[官方网站](https://appports.shimoko.com/)｜[使用文档](https://docs-appports.shimoko.com/)｜[DeepWiki](https://deepwiki.com/wzh4869/AppPorts)

<div style="display:flex; justify-content:center; align-items:center; gap:10px; flex-wrap:nowrap;">
  <a href="https://www.producthunt.com/products/appports/launches/appports?embed=true&utm_source=badge-featured&utm_medium=badge&utm_campaign=badge-appports" target="_blank" rel="noopener noreferrer">
    <img alt="AppPorts - An application migration designed specifically for macOS. | Product Hunt"
         width="250" height="54"
         src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1078207&theme=light&t=1772851420450">
  </a>

  <a href="https://hellogithub.com/repository/wzh4869/AppPorts" target="_blank">
    <img src="https://abroad.hellogithub.com/v1/widgets/recommend.svg?rid=9bc7259839c740faa2246ee5f10bc786&claim_uid=SjNchy8nMfGgUlx&theme=neutral"
         alt="Featured｜HelloGitHub"
         width="250" height="54">
  </a>
</div>

</div>

---

## ✨ 简介

Mac 的内置存储空间寸土寸金。**AppPorts** 允许您一键将 `/Applications` 目录下的应用程序迁移到外部移动硬盘、SD 卡或 NAS，并在原位置保留一个极小的**启动器壳**，让系统误以为应用仍在本地。

对 macOS 系统而言，应用依然"存在"于本地，您可以像往常一样启动它们，但实际占用的却是廉价的外部存储空间。本地启动器壳体积极小，且 Finder **不会显示快捷方式箭头**。

### ⚠️ "AppPorts"已损坏，无法打开
如果打开应用时遇到此提示（且系统建议移到废纸篓），这是因为应用没有进行开发者签名，被 macOS 的 Gatekeeper 机制拦截。
（注意：以下命令假设您已将 AppPorts 拖入 **应用程序** 文件夹）
您需要在终端运行以下命令来移除隔离属性，即可正常打开：
```bash
xattr -rd com.apple.quarantine /Applications/AppPorts.app
```

## 📸 截图

| 欢迎页 | 主界面 |
|:---:|:---:|
| ![Welcome](https://pic.cdn.shimoko.com/appports/huanying.png) | ![Main](https://pic.cdn.shimoko.com/appports/zhuyemian.png) |

| 深色模式 | 语言切换 |
|:---:|:---:|
| ![Dark](https://pic.cdn.shimoko.com/appports/shensemoshi.png) | ![Lang](https://pic.cdn.shimoko.com/appports/yuyan.png) |

## 🚀 核心功能

* **📦 无角标迁移**：一键将几十 GB 的大型应用迁移至外置硬盘。本地仅保留极小的启动器壳，Finder 不显示快捷方式箭头，Launchpad 和 macOS App 菜单正常显示。
* **🛡️ 自动更新保护**：自动识别会自动更新的应用（Sparkle、Electron、Chrome 等），提供**锁定迁移**选项。锁定后外置硬盘上的应用不会被自动更新程序删除或覆盖。
* **✍️ 代码签名管理**：迁移后出现「已损坏」提示？右键一键重签名。支持备份原始签名、恢复原始签名，数据目录迁移后可自动重签名。
* **🔴 孤立链接检测**：外置硬盘拔出或应用被删除后，应用列表会显示红色「孤立链接」标签，方便您清理残留。
* **🍎 macOS 15.1+ App Store 支持**：macOS 15.1+ 可将 App Store 应用直接安装到外置硬盘，App Store 可在外置硬盘上原地更新，无需迁回。
* **↩️ 随时还原**：一键将应用迁回本地并自动移除链接。迁移中断会自动恢复。
* **📊 数据目录管理**：可将应用数据目录（`~/Library/` 子文件夹、`~/.npm` 等）迁移到外部存储。支持树形分组视图、搜索和排序。
* **🎨 现代界面**：原生 SwiftUI 开发，完美适配深色模式，支持 20+ 种语言。
* **♿️ 无障碍**：VoiceOver 友好的语义标签，提供盲文（Braille）语言选项。
* **🌍 全球化**：支持 20+ 种语言，包括 English、中文、日本語、한국어、Deutsch、Français、Español、Italiano、Português、Русский、العربية、हिन्दी、Tiếng Việt、ไทย、Türkçe、Nederlands、Polski、Indonesia、Esperanto、Braille，以及 👽 火星文。

## 🏆 为什么选择 AppPorts？

AppPorts 采用独特的 **Stub Portal（启动器壳）** 技术 — 一个极小的本地壳体启动外置硬盘上的真实应用。兼顾美观、兼容性和系统整洁度。

| 特性 | AppPorts（启动器壳） | 传统软链 |
| :--- | :--- | :--- |
| **Finder 图标** | ✅ 原生（无箭头） | ❌ 有箭头 |
| **Launchpad** | ✅ 完美显示 | ⚠️ 经常失效 |
| **App 菜单 (macOS 26)** | ✅ 完美支持 | ❌ 不支持 |
| **自动更新保护** | ✅ 锁定模式 | ❌ 无保护 |
| **签名管理** | ✅ 内置 | ❌ 无 |
| **孤立链接检测** | ✅ 自动检测 | ❌ 无 |

## 🧭 迁移策略

AppPorts 会根据应用类型和行为自动选择最佳迁移方案：

| 应用类型 | 策略 | 默认开启 | 说明 |
| :--- | :--- | :--- | :--- |
| **普通 Mac 应用** | 启动器壳 | ✅ 是 | 本地极小壳体，无箭头图标 |
| **自更新应用**（Sparkle、Electron 等） | 启动器壳 + 锁定 | ✅ 是 | 外置硬盘上的应用被锁定（uchg），防止自动更新破坏 |
| **iPhone/iPad 应用** | iOS 启动器壳 | ✅ 是 | 从 iOS 应用包提取图标 |
| **Mac App Store 应用** | macOS 15.1+ 原生支持 | ✅ 15.1+ 自动 | App Store 可在外置硬盘上原地更新 |
| **应用套件**（Office、Adobe 等） | 文件夹软链 | ✅ 是 | 整个文件夹作为一个单元迁移 |
| **系统应用** | 阻止 | ❌ | 受保护，不可迁移 |
| **正在运行的应用** | 阻止 | ❌ | 请先退出应用 |
| **已链接的应用** | 阻止 | ❌ | 防止重复链接 |

## 🛠️ 安装与运行

### 系统要求
* macOS 12.0 (Monterey) 或更高版本。

### 下载安装
请前往 [官方网站](https://appports.shimoko.com/) 或 [Releases](https://github.com/wzh4869/AppPorts/releases) 页面下载最新版本的 `AppPorts.dmg`。

### ⚠️ 权限说明
首次运行时，AppPorts 需要 **"完全磁盘访问权限"** 才能读写 `/Applications` 目录。

1. 打开 **系统设置** -> **隐私与安全性**。
2. 选择 **完全磁盘访问权限**。
3. 点击 `+` 号，添加 **AppPorts** 并开启开关。
4. 重启 AppPorts。

*(应用内包含引导页面，可直接跳转至设置)*

## 🧑‍💻 开发构建

```bash
git clone https://github.com/wzh4869/AppPorts.git
```
使用 **Xcode** 打开项目，编译并运行。

## 🤝 贡献

欢迎提交 Issue 或 Pull Request！
如果您发现翻译错误或有新的功能建议，请随时告诉我们。

## AppPorts 的英雄 💗
<a href="https://github.com/wzh4869/AppPorts/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=wzh4869/AppPorts" />
</a>

## 🔗 进阶存储管理

* [LazyMount-Mac](https://github.com/yuanweize/LazyMount-Mac)：轻松扩展 Mac 存储空间 —— 开机自动挂载 SMB 共享与云存储，无需任何手动操作。

  > AppPorts 的最佳拍档。LazyMount 负责连接存储，AppPorts 负责应用程序。
  > * 🎮 游戏库：把 Steam/Epic 游戏放在 NAS 上，玩起来跟本地一样
  > * 💾 时间机器备份：自动备份到远程服务器
  > * 🎬 媒体库：随时访问存放在家庭服务器上的电影/音乐
  > * 📁 项目归档：大文件放在便宜的存储上，按需访问
  > * ☁️ 云存储：把 Google Drive、Dropbox 或任何 rclone 支持的服务挂载成本地文件夹

## Star History

[![Star History Chart](https://star-history.dera.page/svg?repos=wzh4869/AppPorts&type=date&legend=top-left)](https://star-history.dera.page/#wzh4869/AppPorts&type=date&legend=top-left)

## 📄 许可证

本项目基于 [Apache License 2.0](LICENSE) 开源。

<br>
<div align="center">

[个人网站](https://www.shimoko.com) • [GitHub](https://github.com/wzh4869/AppPorts)

</div>
