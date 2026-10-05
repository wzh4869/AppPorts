<div align="center">

<img src="assets/appports-banner-en.png" alt="AppPorts — macOS App & Data Migration" width="100%">

**Move big apps out. Make room for what matters.**
   
Move apps and data to an external drive. Open them as usual.


[English](README.md)｜[简体中文](README_CN.md)｜[Official Website](https://appports.shimoko.com/)｜[Documentation](https://docs-appports.shimoko.com/)｜[DeepWiki](https://deepwiki.com/wzh4869/AppPorts)

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

## ✨ Introduction

Keep your Mac's internal storage free for what you are working on. **AppPorts** is a free, open-source macOS app that moves large applications, app data, and tool directories to external storage.

After migration, the full application lives on the external drive while a lightweight **Stub Portal** stays on your Mac. It keeps the familiar icon without a shortcut arrow. With the drive connected, you can continue opening apps from Finder, the Dock, or the system's app launcher. The migration method depends on the app, macOS version, and storage conditions.

Apps are only part of the picture. WeChat chat history, photos, videos, received files, and other suitable container data can move through **APFS mount migration**: the app reads from its original path, and its original signature stays intact. Suitable ordinary data folders, developer tool directories, and custom folders use symbolic links.

### ⚠️ "AppPorts" is damaged and can't be opened

If an official download of AppPorts shows a “damaged” warning on first launch, Gatekeeper may be blocking an unsigned or unnotarized build. After confirming the source is trustworthy and moving AppPorts into **Applications**, remove its quarantine attribute and try again:

```bash
xattr -rd com.apple.quarantine /Applications/AppPorts.app
```

If a **different app stops opening after migration**, check the drive connection, data mount status, and signature first. For problems caused by older re-signing methods, follow the [macOS 27 upgrade and repair guide](https://docs-appports.shimoko.com/en/macos-27.html).

## 📸 Screenshots

| Readiness Check | Main Interface |
|:---:|:---:|
| ![AppPorts 1.9.0 readiness check](assets/screenshots/en/appports-readiness.png) | ![AppPorts 1.9.0 English interface](assets/screenshots/en/appports-main.png) |

| App Data  | Language Switching (Chinese UI) |
|:---:|:---:|
| ![AppPorts 1.9.0 app data directories](assets/screenshots/en/appports-app-data.png) | ![AppPorts 1.9.0 Chinese interface](assets/screenshots/en/appports-chinese.png) |

## 🚀 Key Features

* **📦 Arrow-Free Migration**: Move large apps to an external drive and keep lightweight local launchers with familiar icons. View local and external apps side by side, and synchronize existing Dock shortcuts when migrating or restoring.
* **🛡️ Auto-Update Protection**: Detect Sparkle, Electron, and other update mechanisms. Offer **locked migration** for suitable apps to protect external copies. Unlock before updating; network volumes do not use these local file locks.
* **✍️ Code Signature Management**: Check signature status and offer repair steps for apps marked “Signature replaced.” Save complete original-app backups and restore original signatures when supported. Default mode refuses to re-sign sandboxed apps.
* **🔴 Orphaned Link Detection**: Mark unavailable targets so you can check the drive connection, locate missing apps, or clean up leftover launchers.
* **🍎 macOS 15.1+ App Store Support**: Work with native external installation and in-place updates for eligible App Store apps, subject to the system's location and format requirements.
* **↩️ Restore Anytime**: Connect the original drive and restore apps or data when your Mac has enough space. Check running apps and name conflicts before operations; attempt recovery on failure, retaining copies and reporting their locations when recovery cannot safely finish.
* **📊 Data Directory Management**: Browse associated app data in grouped trees, search and sort directories, and choose whether to show zero-byte folders. Also manage tool directories such as `~/.npm` and folders you select yourself.
* **💾 APFS Container Migration**: Mount dedicated external APFS volumes at the original paths of suitable Containers and Group Containers data, preserving app signatures. Check for unencrypted APFS storage, connectivity, and available space before migration; mount, unmount, restore, or reconnect data afterward.
* **📐 Clearer Space Totals**: Distinguish local data that can be moved from data already migrated. Avoid counting parent and child directories twice, and flag incomplete totals when reads fail.
* **🔎 Readiness Checks**: Check Full Disk Access, app management, and external storage. Show the running app's version and path to help verify which copy has permission.
* **🎨 Modern UI**: Native SwiftUI with Dark Mode, animated directory expansion, and a resizable information panel.
* **♿️ Accessibility**: VoiceOver labels, keyboard shortcuts, and a Braille language option.
* **🌍 Global Ready**: 20+ languages including English, Chinese, Japanese, Korean, German, French, Spanish, Italian, Portuguese, Russian, Arabic, Hindi, Vietnamese, Thai, Turkish, Dutch, Polish, Indonesian, Esperanto, Braille, and 👽 Martian.

## 🏆 Why AppPorts?

**Move the storage. Keep the familiar experience.** AppPorts uses a **Stub Portal** to retain a lightweight local launcher, with migration status, update protection, signature checks, and restoration in one interface. Manage apps and their data separately to free space where you need it.

| Feature | AppPorts (Stub Portal) | Traditional Symlink |
| :--- | :--- | :--- |
| **Finder Icon** | ✅ Familiar icon, no shortcut arrow | Usually displays a shortcut arrow |
| **Launchpad** | Keeps a local app entry the system can index | Depends on system indexing |
| **App Menu (macOS 26)** | Uses a local `.app` launcher | Depends on how the system recognizes links |
| **Auto-Update Protection** | Lock option for suitable apps | Requires manual maintenance |
| **Signature Management** | Built-in checks, backup, and recovery | Requires separate handling |
| **Orphaned Link Detection** | Automatically flags unavailable targets | Requires manual path checks |

Container data uses APFS mount migration; suitable ordinary directories retain symbolic links. Background components, permissions, and update mechanisms can affect compatibility. See [limitations](https://docs-appports.shimoko.com/en/limitations.html).

## 🧭 Migration Strategy

AppPorts selects a migration method based on the app type, update behavior, and data directory:

| App Type | Strategy | Default | Notes |
| :--- | :--- | :--- | :--- |
| **Native Mac apps** | Stub Portal | ✅ Enabled | Lightweight local entry, full app in external library |
| **Self-updating apps** (Sparkle, Electron, etc.) | Stub Portal + lock where applicable | Based on detection and migration options | Unlock before updating; local file locks are skipped on network volumes |
| **iPhone/iPad apps** | iOS Stub Portal | ✅ Available automatically on macOS 15.1+; setting on older systems | Extracts the icon; running the app still depends on hardware, OS, and app support |
| **Mac App Store apps** | Integrates with native external installation | ✅ Available automatically on macOS 15.1+; setting on older systems | Configure native installation in App Store; older systems may require migrating again after updates |
| **App suites** (folders containing multiple apps) | Folder mirror | ✅ Enabled | Internal apps use launchers; other contents link to external copies |
| **Container data** (Containers / Group Containers) | APFS mount migration | ✅ Default method | Currently requires unencrypted external APFS storage; preserves paths and signatures |
| **Ordinary data, tool directories, and custom folders** | Symbolic links | Where suitable | Original paths link to external data |
| **System apps** | Blocked | ❌ | Protected from migration |
| **Running apps** | Blocked | ❌ | Quit the app first |
| **Already linked apps** | Duplicate linking blocked | ❌ | Check status or restore locally |

Classic data migration mode is off by default. It retains older container symlink and sandboxed-app re-signing behavior, with compatibility depending on the app and macOS version. APFS mount migration is the recommended default; keep container data locally if the drive does not meet its requirements.

**Before upgrading to macOS 27, update and open AppPorts once** so it can update any installed background re-signing script. On macOS 27 and later, login re-signing is disabled and old tasks are cleaned up; retry from Settings if cleanup fails. For affected apps, follow the [repair guide](https://docs-appports.shimoko.com/en/macos-27.html): restore container data migrated through older symbolic links first, then restore the original signature or reinstall from an official source. Updating AppPorts does not automatically convert old migrations or restore replaced signatures.

## 🛠️ Installation

### System Requirements

* macOS 12.0 (Monterey) or newer, on Apple Silicon or Intel Macs.
* A stable external SSD with enough free space is recommended. Format requirements depend on the migration method.
* Container mount migration currently requires **unencrypted APFS** external storage. Older systems may require administrator authorization and opening AppPorts to mount data after login.

### Download and Installation

Download the latest `AppPorts.dmg` from the [official website](https://appports.shimoko.com/) or [Releases](https://github.com/wzh4869/AppPorts/releases).

Move AppPorts into **Applications**, open it, and follow the setup checks. Connect your drive, choose an external app library, and quit the app you intend to move before starting migration. Mount migration requires a stable application path; do not run it directly from a DMG or temporary location.

Keep the drive connected while using migrated apps and data. Allow removable-volume access when macOS requests it. Quit related apps before unmounting or ejecting the drive, and back up important data beforehand. See the [quick start guide](https://docs-appports.shimoko.com/en/faststart.html).

### ⚠️ Permissions

Use the readiness checks to configure **Full Disk Access** for protected app data. macOS may request app management, Finder automation, or administrator authorization depending on the operation.

1. Open **System Settings** → **Privacy & Security**.
2. Select **Full Disk Access**.
3. Click `+`, add the copy of **AppPorts** you are currently running, and enable it.
4. Quit and reopen AppPorts.

*(The in-app guide opens Settings directly. Readiness checks show the running app's version and path; individual directories may still have other access restrictions even after the check passes.)*

## 🧑‍💻 Development

```bash
git clone https://github.com/wzh4869/AppPorts.git
```
Open the project with **Xcode** and build.

## 🤝 Contributing

We welcome Issues and Pull Requests!
If you find translation errors or have suggestions for new features, please let us know.

## AppPorts Heroes 💗
<a href="https://github.com/wzh4869/AppPorts/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=wzh4869/AppPorts" />
</a>

## 💗 Sponsor

AppPorts is completely free, open source and free of ads. It is maintained by a single developer in his spare time and generates no revenue. If it has freed up tens of gigabytes on your disk, you are welcome to scan the QR code and buy the author a coffee — **any amount is welcome, and even the smallest one means a lot**.

<img src="https://pic.cdn.shimoko.com/thanks.png" alt="Sponsor QR code" width="220" />

- When sponsoring, please leave your **nickname** and, optionally, a **link** (GitHub profile, blog, social account, etc.) in the message. They will be shown on the **About AppPorts** page in the app and on the [sponsor page](https://docs-appports.shimoko.com/sponsor.html) of the documentation site.
- There is **no minimum amount** — give whatever feels right. Sponsors are ordered by amount (highest first) and, for equal amounts, by sponsorship date (earliest first); the amount is only shown on the [sponsor page](https://docs-appports.shimoko.com/sponsor.html).

Thanks to the following sponsors (this list is kept in sync with `sponsors.json` in the repository root):

- **师杀** · [space.bilibili.com/396481888](https://space.bilibili.com/396481888)
- **zed**
- **VC**
- **符华**


## Advanced Storage Management

* [LazyMount-Mac](https://github.com/yuanweize/LazyMount-Mac): Easily expand Mac storage space — Automatically mount SMB shares and cloud storage at startup, no manual operation required.

  > The perfect companion for AppPorts. LazyMount connects the storage, AppPorts handles the applications.
  > * 🎮 Game Libraries — Store Steam/Epic games on a NAS, play them like local installs
  > * 💾 Time Machine Backups — Back up to a remote server automatically
  > * 🎬 Media Libraries — Access your movie/music collection stored on a home server
  > * 📁 Project Archives — Keep large files on cheaper storage, access them on-demand
  > * ☁️ Cloud Storage — Mount Google Drive, Dropbox, or any rclone-supported service as a local folder

## Star History

[![Star History Chart](https://star-history.dera.page/svg?repos=wzh4869/AppPorts&type=date&legend=top-left)](https://star-history.dera.page/#wzh4869/AppPorts&type=date&legend=top-left)

## 📄 License

This project is open-source under the [Apache License 2.0](LICENSE).

See the [Privacy Policy](PRIVACY.md).

<br>
<div align="center">

[Personal Website](https://www.shimoko.com) • [GitHub](https://github.com/wzh4869/AppPorts)

</div>
