<div align="center">

<img src="assets/appports-banner.png" alt="AppPorts — macOS App & Data Migration" width="100%">

**大应用，搬出去。好空间，留给你。**

应用和数据迁往外置硬盘，熟悉的打开方式依然在。


[English](README.md)｜[简体中文](README_CN.md)｜[官方网站](https://appports.shimoko.com/)｜[使用文档](https://docs-appports.shimoko.com/)｜[DeepWiki](https://deepwiki.com/wzh4869/AppPorts)

<a href="https://github.com/wzh4869/AppPorts/releases"><img src="https://img.shields.io/github/v/release/wzh4869/AppPorts?style=flat-square&label=release&color=blue" alt="Release"></a>
<a href="https://github.com/wzh4869/AppPorts/stargazers"><img src="https://img.shields.io/github/stars/wzh4869/AppPorts?style=flat-square&color=yellow" alt="Stars"></a>
<a href="https://github.com/wzh4869/AppPorts/network/members"><img src="https://img.shields.io/github/forks/wzh4869/AppPorts?style=flat-square" alt="Forks"></a>
<a href="https://github.com/wzh4869/AppPorts/issues"><img src="https://img.shields.io/github/issues/wzh4869/AppPorts?style=flat-square" alt="Issues"></a>
<a href="https://github.com/wzh4869/AppPorts/blob/main/LICENSE"><img src="https://img.shields.io/github/license/wzh4869/AppPorts?style=flat-square" alt="License"></a>
<img src="https://img.shields.io/badge/platform-macOS-black?style=flat-square&logo=apple&logoColor=white" alt="Platform">
<img src="https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
<a href="https://linux.do"><img src="https://img.shields.io/badge/linux.do-%E7%A4%BE%E5%8C%BA-1f7aec?style=flat-square&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMjAgMTIwIj48Y2xpcFBhdGggaWQ9ImEiPjxjaXJjbGUgY3g9IjYwIiBjeT0iNjAiIHI9IjQ3Ii8%2BPC9jbGlwUGF0aD48cGF0aCBmaWxsPSIjZmZmZmZmIiBjbGlwLXBhdGg9InVybCgjYSkiIGQ9Ik0xMCAxMGgxMDB2MzBIMTB6TTEwIDgwaDEwMHYzMEgxMHoiLz48L3N2Zz4%3D&logoColor=white" alt="linux.do"></a>
<a href="https://docs-appports.shimoko.com/sponsor.html"><img src="https://img.shields.io/badge/%E8%B5%9E%E8%B5%8F-Sponsor-ff69b4?style=flat-square&labelColor=ff69b4&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI%2BPHBhdGggZmlsbD0iI2ZmZmZmZiIgZD0iTTEyIDIxLjM1bC0xLjQ1LTEuMzJDNS40IDE1LjM2IDIgMTIuMjggMiA4LjUgMiA1LjQyIDQuNDIgMyA3LjUgM2MxLjc0IDAgMy40MS44MSA0LjUgMi4wOUMxMy4wOSAzLjgxIDE0Ljc2IDMgMTYuNSAzIDE5LjU4IDMgMjIgNS40MiAyMiA4LjVjMCAzLjc4LTMuNCA2Ljg2LTguNTUgMTEuNTRMMTIgMjEuMzV6Ii8%2BPC9zdmc%2B&logoColor=white" alt="赞赏 · Sponsor"></a>

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

Mac 的内置空间，留给正在做的事。**AppPorts** 是一款免费开源的 macOS 应用与数据迁移工具，帮助您把大型应用、应用数据和工具目录迁移到外部存储，让喜欢的应用和充足的空间同时存在。

迁移应用后，完整应用住进外部库，本机保留一个轻量的 **Stub Portal（启动器壳）**。图标没有快捷方式角标，连接外置盘后，您可以继续从 Finder、Dock 或系统应用入口打开应用。实际迁移方式取决于应用类型、系统版本和存储条件。

占空间的不止应用本身。微信的聊天记录、图片视频、接收文件，以及其他应用的容器数据，也可以通过 **APFS 挂载迁移**放到外置盘：应用继续从原路径读取，原始签名保持不变。普通数据目录、开发工具目录和自定义文件夹则按适用条件使用符号链接迁移。

### ⚠️ "AppPorts"已损坏，无法打开

若从官方渠道下载的 AppPorts 在首次打开时提示「已损坏」，可能是未签名或未公证的构建被 macOS Gatekeeper 拦截。确认下载来源可信，并已将 AppPorts 拖入 **应用程序** 文件夹后，可在终端移除隔离属性，再尝试打开：

```bash
xattr -rd com.apple.quarantine /Applications/AppPorts.app
```

如果是**迁移后的其他应用**无法打开，请先检查外置盘连接、数据挂载和签名状态。旧版重签名导致的问题请按 [macOS 27 升级与修复指南](https://docs-appports.shimoko.com/macos-27.html)处理。

## 📸 截图

| 准备情况 | 主界面 |
|:---:|:---:|
| ![AppPorts 1.9.0 准备情况](assets/screenshots/cn/appports-readiness.png) | ![AppPorts 1.9.0 应用迁移主界面](assets/screenshots/cn/appports-main.png) |

| 应用数据 | 语言切换（English） |
|:---:|:---:|
| ![AppPorts 1.9.0 应用数据目录](assets/screenshots/cn/appports-app-data.png) | ![AppPorts 1.9.0 英文界面](assets/screenshots/cn/appports-english.png) |

## 🚀 核心功能

* **📦 无角标迁移**：将大型应用搬到外置盘，本机保留轻量启动器壳和熟悉的图标。双栏列表展示本地与外部应用，迁移和还原时同步已有 Dock 快捷方式。
* **🛡️ 自动更新保护**：识别 Sparkle、Electron 等更新机制，为适用的自更新应用提供**锁定迁移**选项，保护外部副本。更新前需先解锁；网络卷不使用这类本地文件锁。
* **✍️ 代码签名管理**：检查签名状态，为「签名已替换」的应用提供修复入口。支持保存完整原始应用备份，并在条件满足时恢复原始签名；默认模式拒绝对沙盒应用重签名。
* **🔴 孤立链接检测**：外置盘断开或目标不可用时标记异常链接，方便检查连接状态、定位缺失目标或清理残留入口。
* **🍎 macOS 15.1+ App Store 支持**：结合系统原生外部安装能力处理 App Store 应用，支持符合条件的外部应用原地更新；具体路径和格式要求以系统及应用提示为准。
* **↩️ 随时还原**：连接原来的外置盘，在本机空间充足时将应用或数据迁回。操作前检查运行状态与同名冲突；失败时尝试恢复，无法安全完成的步骤会保留副本并说明路径。
* **📊 数据目录管理**：按应用整理关联数据，支持树形分组、搜索、排序和零字节目录显示开关；也可迁移 `~/.npm` 等工具目录及自行选择的文件夹。
* **💾 APFS 容器迁移**：Containers 和 Group Containers 中适用的数据默认使用专用 APFS 卷挂载到原路径，无需替换应用签名。迁移前检查未加密 APFS、连接状态和可用空间，迁移后提供挂载、卸载、还原与自动接回功能。
* **📐 更清楚的空间统计**：区分本地可迁出数据与已迁移数据，避免父子目录重复计入；遇到读取失败，明确提示统计不完整。
* **🔎 启动自检**：检查完全磁盘访问、应用管理和外部存储状态，显示当前运行版本与路径，方便核对授权对象。
* **🎨 现代界面**：原生 SwiftUI 开发，支持深色模式、树形目录展开动画和可调高度的信息栏，让应用与数据状态更直观。
* **♿️ 无障碍**：提供 VoiceOver 语义标签、键盘快捷键和盲文（Braille）语言选项。
* **🌍 全球化**：支持 20+ 种语言，包括 English、中文、日本語、한국어、Deutsch、Français、Español、Italiano、Português、Русский、العربية、हिन्दी、Tiếng Việt、ไทย、Türkçe、Nederlands、Polski、Indonesia、Esperanto、Braille，以及 👽 火星文。

## 🏆 为什么选择 AppPorts？

**搬走体积，留下熟悉。** AppPorts 使用 **Stub Portal（启动器壳）** 保留轻量的本地应用入口，并把迁移状态、更新保护、签名检查和还原操作放在同一个界面中。应用本体和数据可以分别管理，按需要释放空间。

| 特性 | AppPorts（启动器壳） | 传统软链 |
| :--- | :--- | :--- |
| **Finder 图标** | ✅ 保留应用图标，无快捷方式角标 | 通常带快捷方式箭头 |
| **Launchpad** | 保留可被系统索引的本地应用入口 | 显示情况取决于系统索引 |
| **App 菜单 (macOS 26)** | 使用本地 `.app` 启动入口 | 取决于系统对链接的识别 |
| **自动更新保护** | 为适用应用提供锁定选项 | 需要自行维护 |
| **签名管理** | 内置检查、备份与恢复入口 | 需要另行处理 |
| **孤立链接检测** | 自动标记异常状态 | 需要自行检查目标路径 |

容器数据采用独立的 APFS 挂载迁移，普通数据目录按适用条件保留符号链接。不同应用的后台组件、权限和更新方式可能影响兼容性，详见[使用限制](https://docs-appports.shimoko.com/limitations.html)。

## 🧭 迁移策略

AppPorts 根据应用类型、更新行为与数据目录类型选择迁移方式：

| 应用类型 | 策略 | 默认开启 | 说明 |
| :--- | :--- | :--- | :--- |
| **普通 Mac 应用** | 启动器壳 | ✅ 是 | 本机保留轻量入口，完整应用位于外部库 |
| **自更新应用**（Sparkle、Electron 等） | 启动器壳 + 适用时锁定 | 按检测结果与迁移选项 | 保护外部副本，更新前先解锁；网络卷跳过本地文件锁 |
| **iPhone/iPad 应用** | iOS 启动器壳 | ✅ macOS 15.1+ 自动开放；旧系统按设置 | 提取应用图标，运行仍取决于硬件、系统及应用支持 |
| **Mac App Store 应用** | 结合系统原生外部安装能力 | ✅ macOS 15.1+ 自动开放；旧系统按设置 | 原生外部安装需在 App Store 中配置；旧系统更新后可能需要再次迁移 |
| **应用套件**（文件夹内含多个应用） | 文件夹镜像入口 | ✅ 是 | 内部应用使用启动器，其余内容通过符号链接连接外部副本 |
| **容器数据**（Containers / Group Containers） | APFS 挂载迁移 | ✅ 默认方式 | 当前要求未加密的 APFS 外部存储，保留原路径与原始签名 |
| **普通数据、工具目录和自定义文件夹** | 符号链接 | 按目录适用条件 | 原路径保留链接，数据存放在外部存储 |
| **系统应用** | 阻止 | ❌ | 受保护，不可迁移 |
| **正在运行的应用** | 阻止 | ❌ | 请先退出应用 |
| **已链接的应用** | 阻止重复链接 | ❌ | 可检查状态或还原到本机 |

经典数据迁移模式默认关闭，保留旧的容器符号链接与沙盒重签名行为，兼容性取决于具体应用和系统。默认推荐使用 APFS 挂载迁移；不满足磁盘条件时，可以将容器数据保留在本机。

**准备升级 macOS 27 的旧版用户，请先更新并打开一次 AppPorts**，让新版更新后台重签名脚本。macOS 27 及以上会停用开机自动重签名并清理旧任务。若旧方式迁移的应用无法打开，请按[修复指南](https://docs-appports.shimoko.com/macos-27.html)先还原旧容器符号链接数据，再恢复原始签名或从官方渠道重装；更新 AppPorts 不会自动转换旧迁移方式或恢复签名。

## 🛠️ 安装与运行

### 系统要求

* macOS 12.0 (Monterey) 或更高版本，支持 Apple Silicon 与 Intel Mac。
* 建议使用连接稳定、空间充足的外置 SSD；不同迁移方式对存储格式的要求不同。
* 容器数据挂载迁移当前需要**未加密的 APFS** 外部存储。旧系统可能需要管理员授权，登录后也可能需要打开 AppPorts 手动挂载。

### 下载安装

请前往 [官方网站](https://appports.shimoko.com/) 或 [Releases](https://github.com/wzh4869/AppPorts/releases) 页面下载最新版本的 `AppPorts.dmg`。

将 AppPorts 放入 **应用程序** 文件夹后打开，按引导完成准备，连接外置盘并选择外部应用库。退出要迁移的应用后，即可在应用列表或数据目录中开始迁移。挂载迁移需要稳定的程序路径，请勿直接从 DMG 或临时路径运行。

迁移后使用应用时保持外置盘连接；容器数据首次访问可移动宗卷时，按系统提示授权。拔盘前先退出相关应用并完成卸载或推出。重要数据建议提前备份，更多步骤见[快速入门](https://docs-appports.shimoko.com/faststart.html)。

### ⚠️ 权限说明

首次运行时，请按自检结果配置 **完全磁盘访问权限**，以便读取和迁移受保护的应用数据。应用管理、Finder 自动化或管理员权限会根据实际操作由系统提示。

1. 打开 **系统设置** -> **隐私与安全性**。
2. 选择 **完全磁盘访问权限**。
3. 点击 `+` 号，添加当前使用的 **AppPorts** 并开启开关。
4. 退出并重新打开 AppPorts。

*(应用内包含引导页面，可直接跳转至设置；自检会显示当前运行版本和路径，方便核对授权对象。权限检查通过后，个别目录仍可能存在其他访问限制。)*

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

## 💗 赞助

AppPorts 完全免费、开源、无广告，项目由个人在业余时间维护，没有任何商业收入。如果它帮你省下了几十 GB 的本地空间，欢迎扫码请作者喝杯咖啡 —— **金额不限，一分也是心意**。

<img src="https://pic.cdn.shimoko.com/thanks.png" alt="赞助二维码" width="220" />

- 赞助时请在留言（备注）中留下你的**昵称**，也可以提供**个人链接**（GitHub 主页、博客、社交账号等），它们会展示在 AppPorts 的「关于 AppPorts」页面以及[网站赞助页](https://docs-appports.shimoko.com/sponsor.html)。
- 赞助**没有最低金额要求**，多少随意，量力而行就好；赞助者按**金额从高到低**排序，金额相同时按**赞助时间从早到晚**排序，金额仅在[网站赞助页](https://docs-appports.shimoko.com/sponsor.html)展示。

感谢以下赞助者（此列表与仓库根目录的 `sponsors.json` 同步）：

- **师杀** · [space.bilibili.com/396481888](https://space.bilibili.com/396481888)
- **zed**
- **VC**
- **符华**
 
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

隐私政策见 [PRIVACY.md](PRIVACY.md)。

<br>
<div align="center">

[个人网站](https://www.shimoko.com) • [GitHub](https://github.com/wzh4869/AppPorts)

</div>
