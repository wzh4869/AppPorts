<div align="center">

# 📦 AppPorts

**External drives save the world\!**

An application migration and linking tool designed exclusively for macOS.
Easily move large applications to external storage while maintaining seamless system operation.

[English](README.md) | [简体中文](https://www.google.com/search?q=README_CN.md)

\</div\>

-----

## ✨ Introduction

Built-in storage space on a Mac is precious. **AppPorts** allows you to instantly move applications from your `/Applications` directory to an external drive, SD card, or NAS, and automatically create a **Symbolic Link** in the original location.

To the macOS system and Launchpad, the application still "exists" locally, allowing you to launch it as usual, but the actual space is consumed by your more affordable external storage.

## 🚀 Features

  * **📦 App Slimming**: One-click migration of multi-GB applications (e.g., Logic Pro, Xcode, games, etc.) to an external drive.
  * **🔗 Seamless Linking**: Automatically creates symbolic links in the original location, preserving system indexing and Launchpad functionality.
  * **🛡️ Safety First**:
      * Automatically identifies and locks **System Apps** to prevent accidental system corruption.
      * Checks the **Running Status** before migration to prevent damaging applications that are currently in use.
  * **↩️ Restore Anytime**: Simply click "Restore" to move the application back to your local disk completely; the symbolic link is automatically removed.
  * **🎨 Modern UI**:
      * Developed natively with SwiftUI for a smooth and fluid experience.
      * Perfect adaptation for **Dark Mode**.
      * Supports **Bi-lingual (Chinese/English)**, switchable with system settings or manually.
  * **🔍 Quick Search**: Built-in search bar for quickly locating local or external applications.

## 📸 Screenshots

| Welcome | Main |
|:---:|:---:|
| ![Welcome](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.24.png) | ![Main](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.34.png) |

| Dark Mode | Localization  |
|:---:|:---:|
| ![Dark](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.45.png) | ![Lang](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.52.11.png) |

## 🛠️ Installation and Running

### System Requirements

  * macOS 14.0 (Sonoma) or newer.

### Download and Install

Please download the latest `AppPorts.dmg` from the [Releases](https://github.com/wzh4869/AppPorts/releases) page.

### ⚠️ Permissions Note

The first time you run AppPorts, it requires **"Full Disk Access"** to read and write to the `/Applications` directory.

1.  Open **System Settings** -\> **Privacy & Security**.
2.  Select **Full Disk Access**.
3.  Click the `+` sign, add **AppPorts**, and toggle the switch ON.
4.  Restart AppPorts.

*(The application includes an onboarding page that can directly navigate you to the settings.)*

## 🧑‍💻 Development

If you are a developer and wish to build the project yourself:

1.  Clone the repository:
    ```bash
    git clone https://github.com/wzh4869/AppPorts.git
    ```
2.  Open the project with **Xcode**.
3.  Compile and Run.

## 🤝 Contributing

We welcome Issues and Pull Requests\!
If you find translation errors or have suggestions for new features, please let us know.

## 📄 License

This project is open-sourced under the [MIT License](https://www.google.com/search?q=LICENSE).

-----

<div align="center">

Created by **Shimoko**

[Personal Website](https://www.shimoko.com) • [GitHub](https://github.com/wzh4869)

</div>
