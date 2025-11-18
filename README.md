<div align="center">

# 📦 AppPorts

**External drives save the world!**

A macOS utility tool designed to migrate applications to external storage seamlessly.
Free up your Mac's local space while keeping apps running as normal.

[简体中文](README.md) | [English](README_EN.md)

</div>

---

## ✨ Introduction

Mac storage is expensive. **AppPorts** allows you to move applications from your local `/Applications` folder to an external drive, SD card, or NAS with a single click. It automatically creates a **Symbolic Link** in the original location.

To macOS and Launchpad, the app still "exists" locally, allowing you to launch it as usual, while the actual data resides on your external storage.

## 🚀 Features

* **📦 App Slimming**: Migrate huge apps (Logic Pro, Xcode, Games) to external drives easily.
* **🔗 Seamless Linking**: Auto-creates symlinks. Apps work perfectly with Launchpad and Spotlight.
* **🛡️ Safety First**:
    * Identifies and locks **System Apps** to prevent damage.
    * Checks **Running Status** before migration to prevent data loss.
* **↩️ Restore Anytime**: Move apps back to the local disk with one click.
* **🎨 Modern UI**:
    * Built with native SwiftUI.
    * Full **Dark Mode** support.
    * **Bi-lingual** support (English/Chinese), switchable in-app.
* **🔍 Search**: Built-in search bar to find apps quickly.

## ⚠️ Permissions

AppPorts requires **"Full Disk Access"** to modify the `/Applications` folder.
Please enable it in **System Settings** -> **Privacy & Security** -> **Full Disk Access**.

## 📄 License

This project is licensed under the [MIT License](LICENSE).

---

<div align="center">

Created by **Shimoko**

[Website](https://www.shimoko.com) • [GitHub](https://github.com/wzh4869)

</div>
