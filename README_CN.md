<div align="center">

# 📦 AppPorts

**外置硬盘拯救世界！/ External drives save the world!**

一款专为 macOS 设计的应用程序迁移与链接工具。  
轻松将庞大的应用程序迁移至外部存储，同时保持系统无感运行。

[English](README.md) | [简体中文](README_CN.md)

</div>

---

## ✨ 简介 (Introduction)

Mac 的内置存储空间寸土寸金。**AppPorts** 允许您一键将 `/Applications` 目录下的应用程序迁移到外部移动硬盘、SD 卡或 NAS，并在原位置保留**应用入口 (App Portal)**，让系统误以为应用仍在本地。

对 macOS 系统而言，应用依然“存在”于本地，您可以像往常一样启动它们，但实际占用的却是廉价的外部存储空间。

## 🚀 核心功能 (Features)

* **📦 应用瘦身 (App Slimming)**：一键将几十 GB 的大型应用（如 Logic Pro, Xcode, 游戏等）迁移至外置硬盘。
* **🔗 Contents**：采用 **Contents 目录链接** 方案，专为适配 macOS 机制设计。
    *   **原理**：在本地保留 `.app` 文件夹结构，仅将内部的 `Contents` 数据目录链接至外部存储。
    *   **空间占用**：本地仅保留文件夹索引信息，占用空间受文件系统块大小限制（通常可忽略不计）。
    *   **兼容性**：Finder 不会显示快捷方式小箭头，且支持 macOS 26 的 **"App 菜单"** 显示。
* **🛡️ 安全机制 (Safety First)**：
    * 自动识别并锁定 **系统应用** (System Apps)，防止误操作破坏系统。
    * 迁移前检测 **运行状态**，防止损坏正在运行的应用。
* **↩️ 随时还原 (Restore Anytime)**：只需点击“还原”，即可将应用完整迁回本地磁盘，符号链接自动移除。
* **🎨 现代 UI (Modern UI)**：
    * 原生 SwiftUI 开发，丝滑流畅。
    * 完美适配 **深色模式 (Dark Mode)**。
    * 支持 **中英双语 (Bi-lingual)**，可随系统或手动切换。
* **🔍 快速检索**：内置搜索栏，快速定位本地或外部应用。

## 🏆 为什么选择 AppPorts？(技术对比)

相较于市面上其他方案，AppPorts 采用了独特的 **Contents 链接** 技术，兼顾了美观、兼容性与系统整洁度。

| 方案 | AppPorts (Contents 链接) | 传统软链 (ln -s .app) |
| :--- | :--- | :--- |
| **Finder 图标** | ✅ **原生 (无箭头)** | ❌ 有箭头 (快捷方式) |
| **Launchpad** | ✅ **完美索引** | ⚠️ 经常失效 |
| **App 菜单 (macOS 26)** | ✅ **完美支持** | ❌ 不支持 |
| **文件系统整洁度** | ✅ **极佳 (仅1个链接)** | ✅ 极佳 (仅1个链接) |
| **维护与还原** | ✅ **毫秒级** | ✅ 毫秒级 |

## 📸 截图 (Screenshots)

| 欢迎页 (Welcome) | 主界面 (Main) |
|:---:|:---:|
| ![Welcome](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.24.png) | ![Main](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.34.png) |

| 深色模式 (Dark Mode) | 语言切换 (Localization) |
|:---:|:---:|
| ![Dark](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.45.png) | ![Lang](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.52.11.png) |

## 🛠️ 安装与运行 (Installation)

### 系统要求
* macOS 14.0 (Sonoma) 或更高版本。

### 下载安装
请前往 [Releases](https://github.com/wzh4869/AppPorts/releases) 页面下载最新版本的 `AppPorts.dmg`。

### ⚠️ 权限说明 (Permissions)
首次运行时，AppPorts 需要 **“完全磁盘访问权限 (Full Disk Access)”** 才能读写 `/Applications` 目录。

1.  打开 **系统设置 (System Settings)** -> **隐私与安全性 (Privacy & Security)**。
2.  选择 **完全磁盘访问权限 (Full Disk Access)**。
3.  点击 `+` 号，添加 **AppPorts** 并开启开关。
4.  重启 AppPorts。

*(应用内包含引导页面，可直接跳转至设置)*

## 🧑‍💻 开发构建 (Development)

如果您是开发者，想要自行构建项目：

1.  克隆仓库：
    ```bash
    git clone https://github.com/wzh4869/AppPorts.git
    ```
2.  使用 **Xcode** 打开项目。
3.  编译并运行。

## 🤝 贡献 (Contributing)

欢迎提交 Issue 或 Pull Request！
如果您发现翻译错误或有新的功能建议，请随时告诉我们。

## 📄 许可证 (License)

本项目基于 [MIT License](LICENSE) 开源。

---

<div align="center">

Created by **Wzh4869**

[个人网站](https://www.shimoko.com) • [GitHub](https://github.com/wzh4869)

</div>
