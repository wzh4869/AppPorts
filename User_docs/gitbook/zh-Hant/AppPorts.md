---
icon: "compass"
layout:
  width: "default"
  outline:
    visible: true
---

# AppPorts 使用者指南

本指南系統介紹 AppPorts 的核心功能、設計原則與技術實作。更多技術細節可參閱 [DeepWiki](https://deepwiki.com/wzh4869/AppPorts)。如有改進建議，歡迎在專案 [Issues](https://github.com/wzh4869/AppPorts/issues) 中回報。

## 概述 <a href="#概述" id="概述"></a>

AppPorts 是專為 [macOS](https://www.apple.com.cn/os/macos/) 設計的應用程式遷移與連結工具。它可以將大型應用程式遷移到外接儲存裝置，並儘量保持 Finder、Launchpad、應用程式選單和系統更新行為的一致性。

### AppPorts 哲學 <a href="#appports-哲學" id="appports-哲學"></a>

| 原則 | 說明 |
|------|------|
| **透明體驗** | 儘量讓使用者和作業系統都像使用本機應用程式一樣使用已遷移應用程式 |
| **策略穩定** | 優先採用經過驗證、遷移穩定性更高的方案 |
| **低系統負擔** | 不依賴背景常駐行程，避免持續佔用系統資源 |
| **廣泛國際化** | 優先覆蓋更多語言，持續改進翻譯質量 |
| **無障礙友好** | 提供較完整的無障礙取用支援 |

## 核心功能 <a href="#核心功能" id="核心功能"></a>

- **無角標遷移**：一鍵將大型應用程式遷移至外接儲存裝置。本機僅保留輕量啟動器殼，Finder 不顯示捷徑箭頭，Launchpad 與 macOS 應用程式選單正常顯示。
- **自動更新保護**：自動辨識支援自更新的應用程式（Sparkle、Electron、Chrome 等），提供「锁定遷移」選項，防止外接儲存裝置上的應用程式被自動更新程式刪除或覆蓋。
- **版本同步提示**：當本機真實應用程式版本高於外接儲存裝置中的舊副本時，標記為「待遷出」，提示可將本機新版遷出並替換外部舊版本。
- **Stub Portal 版本同步**：外接硬碟上的應用程式透過 App Store 更新後，本機 Stub Portal 的版本資訊會自動同步，「開啟方式」選單始終顯示正確版本。
- **自訂掃描目錄**：支援新增額外的本機應用程式掃描目錄（如 JetBrains Toolbox、Steam 等），自動儲存並監控變化。
- **程式碼簽名管理**：應用程式本體遷移後如出現「已損壞」提示，可透過右鍵選單重簽名，支援備份與恢復原始簽名。沙盒應用程式一律不重簽名。
- **macOS 15.1+ App Store 支援**：支援將 App Store 應用程式直接安裝至外接儲存裝置，並在外接儲存裝置上原地更新，無需遷回本機。
- **一鍵還原**：支援將應用程式遷回本機並自動移除連結。遷移中斷時可自動恢復。
- **資料目錄管理**：支援將應用程式資料目錄（`~/Library/` 子目錄、`~/.npm` 等）遷移至外接儲存裝置，提供樹狀群組檢視、搜尋與排序功能，並透過 AppPorts metadata 嚴格驗證恢復目標。
- **容器資料掛載遷移**：微信聊天記錄等沙盒容器資料透過在 APFS 外接磁碟上建立獨立卷宗並掛載到原目錄的方式遷移，應用程式簽名不做任何修改。
- **目錄遷移**：支援將使用者目錄下的任意真實資料夾遷移到外接儲存裝置，適合大型專案、模型、素材庫和工具快取，並提供接回、還原和路徑重疊驗證。


## 遷移策略 <a href="#遷移策略" id="遷移策略"></a>

### Deep Contents Wrapper（Contents 目錄遷移） <a href="#deep-contents-wrapper-contents-目錄遷移" id="deep-contents-wrapper-contents-目錄遷移"></a>

macOS 應用程式的標準檔案結構如下：

```text
/Applications/Safari.app/
├── Contents/
│   ├── MacOS/
│   ├── Resources/
│   ├── Frameworks/
│   └── Info.plist
└── ...
```

Deep Contents Wrapper 策略會將應用程式的全部內容遷移至外接儲存裝置，並在本機建立同名的空 `.app` 目錄，其中僅包含指向外接儲存裝置 `Contents` 目錄的符號連結。由於 macOS 偵測到的是一個完整的 `.app` 套件（而非捷徑），Finder 不會顯示箭頭標記，圖示、Launchpad 與應用程式選單均可正常工作。

{% hint style="warning" %}
**此策略已在目前版本中棄用**

Deep Contents Wrapper 的主要缺陷在於：自動更新程式執行時可能沿符號連結直接操作外接儲存裝置上的檔案，從而破壞應用程式本體。
{% endhint %}

### Stub Portal（殼門方案） <a href="#stub-portal-殼門方案" id="stub-portal-殼門方案"></a>

Stub Portal 方案在本機建立一個最小化的 `.app` 殼，僅包含以下四項內容：

| 元件 | 說明 |
|------|------|
| `Contents/MacOS/launcher` | 啟動器，執行 `open "/Volumes/External/SomeApp.app"` |
| `Contents/Resources/` | 從外部應用程式複製的圖示檔案 |
| `Contents/Info.plist` | 基於外部應用程式的 `Info.plist` 精簡產生，將 `CFBundleExecutable` 設為 `launcher`，新增 `LSUIElement=true`（不在 Dock 顯示），移除所有更新相關設定鍵 |
| `Contents/PkgInfo` | 標準的 4 位元組識別檔案 |

使用者按一下此殼時，macOS 會執行 `launcher`，並透過 `open` 命令啟動外接儲存裝置上的真實應用程式。本機不包含符號連結，因此自動更新程式無法沿連結穿透到外部應用程式。

### iOS Stub Portal（iOS 殼門方案） <a href="#ios-stub-portal-ios-殼門方案" id="ios-stub-portal-ios-殼門方案"></a>

基本原理與標準 Stub Portal 一致，但圖示處理方式不同。iOS 應用程式的圖示不在 `Info.plist` 中指定，而是儲存在 `Wrapper/` 或 `WrappedBundle/` 目錄下的多個 `AppIcon.png` 檔案中。處理流程如下：

1. 查詢解析度最大的 `AppIcon.png` 檔案
2. 使用 `sips` 縮放至 256×256 像素
3. 使用 `sips` 轉換為 `.icns` 格式
4. 基於 `iTunesMetadata.plist` 產生 `Info.plist`（iOS 應用程式不包含標準 `Info.plist`）

### Whole Symlink（整體符號連結） <a href="#whole-symlink-整體符號連結" id="whole-symlink-整體符號連結"></a>

將整個 `.app` 目錄建立為指向外接儲存裝置的符號連結：

```text
/Applications/SomeApp.app → /Volumes/External/SomeApp.app
```

本機僅保留一個符號連結，不包含實際應用程式檔案。macOS 通常可以正常開啟應用程式，但 Finder 會在圖示上顯示捷徑箭頭，Launchpad 也可能出現相容性問題。此外，自動更新程式同樣可能沿符號連結操作外接儲存裝置上的應用程式檔案。因此，該方式主要作為 AppPorts 的備援遷移策略。
