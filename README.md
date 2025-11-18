<div align="center">

# 📦 AppPorts

**External drives save the world!**

An application migration and linking tool designed specifically for macOS.
Easily migrate large applications to external storage while maintaining seamless system functionality.

[Simplified Chinese](README_CN.md)

</div>

---

## ✨ Introduction

Mac's built-in storage space is extremely precious. **AppPorts** allows you to move applications from your `/Applications` directory to an external drive (SSD, SD Card, or NAS) with a single click, and automatically creates a **Symbolic Link** in the original location.

To macOS and Launchpad, the app still "exists" locally, allowing you to launch it as usual, but the storage occupied is on inexpensive external media.

## 🚀 Key Features

* **📦 App Slimming**: One-click migration of multi-gigabyte applications (e.g., Logic Pro, Xcode, games) to an external drive.
* **🔗 Seamless Linking**: Automatically creates soft links (symlinks) in place, preserving system indexes and ensuring applications launch correctly from Launchpad.
* **🛡️ Safety First**:
    * Automatically identifies and locks **System Apps** to prevent accidental system corruption.
    * Checks the **Running Status** before migration to avoid corrupting active applications.
* **↩️ Restore Anytime**: Simply click "Restore" to move the application back to the local disk, automatically removing the symbolic link.
* **🎨 Modern UI**:
    * Developed natively with SwiftUI for a smooth, fluid experience.
    * Perfect compatibility with **Dark Mode**.
    * Supports **Bi-lingual** (English/Chinese), switchable via system or in-app menu.
* **🔍 Quick Search**: Built-in search bar to quickly locate local or external applications.

## 📸 Screenshots

| Welcome Screen | Main Interface |
|:---:|:---:|
| ![Welcome](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.24.png) | ![Main](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.34.png) |

| Dark Mode | Language Switching |
|:---:|:---:|
| ![Dark](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.51.45.png) | ![Lang](https://pic.cdn.shimoko.com/%E6%88%AA%E5%B1%8F2025-11-19%2002.52.11.png) |

## 🛠️ Installation

### System Requirements
* macOS 14.0 (Sonoma) or newer.

### Download and Installation
Please visit the [Releases](https://github.com/wzh4869/AppPorts/releases) page to download the latest `AppPorts.dmg`.

### ⚠️ Permissions
Upon first run, AppPorts requires **Full Disk Access** to read and modify the `/Applications` directory.

1. Open **System Settings** → **Privacy & Security**.
2. Select **Full Disk Access**.
3. Click the `+` button, add **AppPorts**, and turn on the toggle.
4. Relaunch AppPorts.

*(The application includes an in-app guide for direct navigation to settings)*

## 🧑‍💻 Development

If you are a developer and wish to build the project yourself:

1. Clone the repository:
   ```bash
   git clone [https://github.com/wzh4869/AppPorts.git](https://github.com/wzh4869/AppPorts.git)
    ```
2.  Open the project with **Xcode**.
3.  Compile and Run.

## 🤝 Contributing

We welcome Issues and Pull Requests\!
If you find translation errors or have suggestions for new features, please let us know.

## 📄 License

This project is open-source under the [MIT License](LICENSE).

<br>
<div align="center">

Created by **Shimoko**

[Personal Website](https://www.shimoko.com) • [GitHub](https://github.com/wzh4869/macappports)

</div>
