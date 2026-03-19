<div align="center">

# 📦 AppPorts

**External drives save the world!**

An application migration and linking tool designed specifically for macOS.
Easily migrate large applications to external storage while maintaining seamless system functionality.

[简体中文](README_CN.md)｜[Official Website](https://appports.shimoko.com/)｜[DeepWiki](https://deepwiki.com/wzh4869/AppPorts)

<div style="display:flex; justify-content:center; align-items:center; gap:10px; flex-wrap:wrap;">
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

Mac's built-in storage space is extremely precious. **AppPorts** allows you to move applications from your `/Applications` directory to an external drive (SSD, SD Card, or NAS) with a single click, while keeping a valid **App Portal** in the original location.

To macOS, the app still "exists" locally, allowing you to launch it as usual, but the storage occupied is on inexpensive external media.

### ⚠️ "AppPorts" is damaged and can't be opened
If you encounter this error (and macOS suggests moving it to the Trash) when opening the app, it is because the application is not signed with an Apple Developer ID.
(Note: The command below assumes you have moved AppPorts to the **/Applications** folder)
To fix this, please run the following command in Terminal to remove the quarantine attribute:
```bash
xattr -rd com.apple.quarantine /Applications/AppPorts.app
```

## 📸 Screenshots

| Welcome Screen | Main Interface |
|:---:|:---:|
| ![Welcome](https://pic.cdn.shimoko.com/appports/huanying.png) | ![Main](https://pic.cdn.shimoko.com/appports/zhuyemian.png) |

| Dark Mode | Language Switching |
|:---:|:---:|
| ![Dark](https://pic.cdn.shimoko.com/appports/shensemoshi.png) | ![Lang](https://pic.cdn.shimoko.com/appports/yuyan.png) |

## 🚀 Key Features

* **📦 App Slimming**: One-click migration of multi-gigabyte applications such as Logic Pro, Xcode, and games to external storage.
* **🔗 Contents Linking**: Keeps the `.app` bundle structure locally and links only the internal `Contents` directory to the external drive. Local disk usage is usually negligible, Finder shows no shortcut arrow, and the result works with the **"App Menu"** in macOS 26.
* **🛡️ Safety First**: Automatically identifies and locks **System Apps**, and checks the **Running Status** before migration to avoid damaging active applications.
* **↩️ Restore Anytime**: Click **Restore** to move the application back to the local disk and remove the symbolic link automatically.
* **🎨 Modern UI**: Built natively with SwiftUI, fully supports **Dark Mode**, and supports **Bi-lingual** (English/Chinese) switching via system or in-app menu.
* **♿️ Accessibility Plus**: Includes **VoiceOver**-friendly row announcements, clearer semantic UI, and a **Braille** language option that displays interface text directly in Braille dots.
* **🌍 Global Ready**: Supports 20+ languages including 🇺🇸 English, 🇨🇳 Simplified Chinese, 🇭🇰 Traditional Chinese, 🇯🇵 Japanese, 🇰🇷 Korean, 🇩🇪 German, 🇫🇷 French, 🇪🇸 Spanish, 🇮🇹 Italian, 🇵🇹 Portuguese, 🇷🇺 Russian, 🇸🇦 Arabic, 🇮🇳 Hindi, 🇻🇳 Vietnamese, 🇹🇭 Thai, 🇹🇷 Turkish, 🇳🇱 Dutch, 🇵🇱 Polish, 🇮🇩 Indonesian, 🏁 Esperanto, and ⠃⠗ Braille. File sizes also respect localized formatting rules.
* **🔍 Quick Search**: Built-in search bar for quickly locating local or external applications.

## 🏆 Why AppPorts?

Compared to other solutions, AppPorts uses the unique **Contents Linking** technology, balancing aesthetics, compatibility, and system cleanliness.

| Strategy | AppPorts | Traditional Symlink |
| :--- | :--- | :--- |
| **Finder Icon** | ✅ **Native (No Arrow)** | ❌ Arrow Overlay |
| **Launchpad** | ✅ **Perfect** | ⚠️ Unreliable |
| **App Menu (macOS 26)**| ✅ **Perfect** | ❌ Unsupported |
| **FS Cleanliness** | ✅ **Clean (1 Link)** | ✅ Clean (1 Link) |
| **Maintenance** | ✅ **Instant** | ✅ Instant |

## 🧭 Migration Strategy

AppPorts does not migrate every app in the same way. It picks a local portal strategy based on the app's structure and update behavior.

| App Type | Default Strategy | Default Availability | Notes |
| :--- | :--- | :--- | :--- |
| Native macOS apps | Keep a local `.app` wrapper and link `Contents` | Enabled | The default strategy for most regular apps |
| Self-updating apps | Symlink the whole app bundle | Enabled | Better suited for apps that ship updater components such as Sparkle or Squirrel |
| iPhone/iPad apps on Mac | Symlink the whole app bundle | Disabled by default | Can be enabled manually in settings |
| Mac App Store apps | Migrate only after opt-in, then follow the detected bundle strategy | Disabled by default | More sensitive to system protections and update flow |
| App suites or folders containing multiple apps | Move and symlink the whole folder | Enabled | Better suited for suite-style distributions |
| System apps | Not migrated | Blocked | Protected to avoid damaging the system |
| Running apps | Not migrated | Blocked | Quit the app before migrating |
| Already linked apps | Not migrated again | Blocked | Prevents double-linking and broken states |

## 🛠️ Installation

### System Requirements
* macOS 14.0 (Sonoma) or newer.

### Download and Installation
Please visit the [official website](https://appports.shimoko.com/) or the [Releases](https://github.com/wzh4869/AppPorts/releases) page to download the latest `AppPorts.dmg`.


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
   git clone https://github.com/wzh4869/AppPorts.git
    ```
2.  Open the project with **Xcode**.
3.  Compile and Run.

## 🤝 Contributing

We welcome Issues and Pull Requests\!
If you find translation errors or have suggestions for new features, please let us know.
## AppPorts Heroes💗  
<a href="https://github.com/wzh4869/AppPorts/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=wzh4869/AppPorts" />
</a>

##  Advanced Storage Management

* [LazyMount-Mac](https://github.com/yuanweize/LazyMount-Mac): Easily expand Mac storage space — Automatically mount SMB shares and cloud storage at startup, no manual operation required.
    
  > The perfect companion for AppPorts. LazyMount connects the storage, AppPorts handles the applications.
    *   🎮 Game Libraries — Store Steam/Epic games on a NAS, play them like local installs
    *   💾 Time Machine Backups — Back up to a remote server automatically
    *   🎬 Media Libraries — Access your movie/music collection stored on a home server
    *   📁 Project Archives — Keep large files on cheaper storage, access them on-demand
    *   ☁️ Cloud Storage — Mount Google Drive, Dropbox, or any rclone-supported service as a local folder

## Star History

[![Star History Chart](https://api.star-history.com/image?repos=wzh4869/AppPorts&type=date&legend=top-left)](https://www.star-history.com/?repos=wzh4869%2FAppPorts&type=date&legend=top-left)
## 📄 License

This project is open-source under the [Apache License 2.0](LICENSE).

<br>
<div align="center">

[Personal Website](https://www.shimoko.com) • [GitHub](https://github.com/wzh4869/AppPorts)

</div>
