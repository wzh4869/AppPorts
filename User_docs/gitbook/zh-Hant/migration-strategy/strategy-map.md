# 應用類型與策略對照

| 應用類型 | 容器分類 | 遷移策略 | 鎖定保護 | 說明 |
|----------|----------|----------|----------|------|
| 原生 macOS 應用（無自更新） | `standaloneApp` | macOS Stub Portal | 否 | 如 Safari、Finder |
| Sparkle 自更新應用 | `standaloneApp` | macOS Stub Portal | **是** | 如部分獨立開發者應用 |
| Electron 應用（無 `app-update.yml`） | `standaloneApp` | macOS Stub Portal | 否 | 如 VS Code |
| Electron 應用（有 `app-update.yml`） | `standaloneApp` | macOS Stub Portal | **是** | 如 Slack、Discord |
| Electron + Sparkle 混合應用 | `standaloneApp` | macOS Stub Portal | **是** | 兩個標誌獨立檢測，同時成立 |
| 自定義更新器應用（Chrome、Edge） | `standaloneApp` | macOS Stub Portal | 否 | 通過 `LaunchServices`、`KSProductID` 等識別 |
| iOS 應用（Mac 版） | `standaloneApp` | iOS Stub Portal | 否 | 圖標從 `WrappedBundle` 提取，不簽名 |
| Mac App Store 應用 | `standaloneApp` | macOS Stub Portal | 否 | SIP 保護，無法重簽名 |
| 單應用容器目錄 | `singleAppContainer` | Whole App Symlink | 否 | 目錄內僅 1 個 `.app`，整體符號鏈接 |
| 應用套件目錄（如 Office） | `appSuiteFolder` | Whole App Symlink | 視內部應用而定 | 目錄內 2+ 個 `.app`，整體符號鏈接 |
| 非 `.app` 路徑 | — | Whole App Symlink | — | 擴展名不爲 `.app` 的路徑 |

{% hint style="warning" %}
**⚠️ 關於鎖定保護**

當應用被標記爲需要鎖定（`needsLock = true`）時，AppPorts 在遷移完成後對外部存儲上的應用執行 `chflags -R uchg`，設置不可變標誌。這會阻止自更新程序刪除或修改外部副本，但也意味着應用無法自行更新。用戶需要在 AppPorts 中手動解鎖後才能進行更新。
{% endhint %}

{% hint style="success" %}
**💡 自定義更新器應用爲何不鎖定**

Chrome、Edge 等使用自定義更新器的應用不會被鎖定。這類應用的更新程序通常會將新版本下載並安裝到本地內部存儲，受到 macOS Stub Portal 的鏈接隔離特性，因此不會破壞外部存儲上的應用文件。

當 AppPorts 檢測到本地內部存儲上的應用版本高於外部存儲上的版本時，會自動爲該應用打上「待遷出」標籤，提示用戶需要重新遷移以同步最新版本。
{% endhint %}
