---
icon: "arrows-rotate"
description: "查看自動更新應用程式的辨識與保護機制。"
layout:
  width: "default"
  outline:
    visible: true
---

# 自更新應用識別

## Electron 應用識別 <a href="#electron-應用識別" id="electron-應用識別"></a>

AppPorts 通過以下三個檢測條件識別 Electron 應用（按優先級依次檢查，短路求值）：

| # | 檢測項 | 路徑 / 模式 |
|---|--------|-------------|
| 1 | Electron Framework | `Contents/Frameworks/Electron Framework.framework` 目錄存在 |
| 2 | Electron Helper 變體 | `Contents/Frameworks/` 下存在名稱包含 `Electron Helper` 的條目 |
| 3 | Info.plist 標識鍵 | `Contents/Info.plist` 中存在 `ElectronDefaultApp` 或 `electron` 鍵 |

### Electron 自更新檢測 <a href="#electron-自更新檢測" id="electron-自更新檢測"></a>

額外檢查是否存在 `Contents/Resources/app-update.yml` 文件（`electron-updater` 的配置文件），若存在則標記該 Electron 應用具有自更新能力。

## Sparkle 應用識別 <a href="#sparkle-應用識別" id="sparkle-應用識別"></a>

AppPorts 通過以下三個檢測條件識別 Sparkle 應用：

| # | 檢測項 | 路徑 / 模式 |
|---|--------|-------------|
| 1 | Sparkle 框架 | `Contents/Frameworks/Sparkle.framework` 或 `Contents/Frameworks/Squirrel.framework` 存在 |
| 2 | 更新器二進制文件 | `Contents/MacOS/` 或 `Contents/Frameworks/` 下存在匹配 `shipit`、`autoupdate`、`updater`、`update` 的文件 |
| 3 | Info.plist Sparkle 鍵 | `Contents/Info.plist` 中存在以下任一鍵：`SUFeedURL`、`SUPublicDSAKeyFile`、`SUPublicEDKey`、`SUScheduledCheckInterval`、`SUAllowsAutomaticUpdates` |

{% hint style="warning" %}
**⚠️ Electron 應用的特殊處理**

當應用已被識別爲 Electron 應用時，檢測條件 #2（更新器二進制文件）會被跳過，以避免 `electron-updater` 的 `updater` 二進制文件導致誤判爲 Sparkle 應用。
{% endhint %}

## 混合 Electron + Sparkle 應用 <a href="#混合-electron-sparkle-應用" id="混合-electron-sparkle-應用"></a>

部分應用同時包含 Electron 框架和 Sparkle 更新器。AppPorts 對兩個標誌獨立檢測，允許 `isElectron` 和 `isSparkle` 同時爲 `true`。

### 檢測邏輯 <a href="#檢測邏輯" id="檢測邏輯"></a>

```text
isElectron = 滿足 Electron 三個檢測條件之一
isSparkle  = 滿足 Sparkle 三個檢測條件之一（Electron 應用跳過條件 #2）
```

兩個標誌互不影響，可同時成立。

### 遷移後行爲 <a href="#遷移後行爲" id="遷移後行爲"></a>

| 屬性 | 判定條件 |
|------|----------|
| `hasSelfUpdater` | `isSparkle` 或 (`isElectron` 且存在 `app-update.yml`) 或 存在自定義更新器 |
| `needsLock` | `isSparkle` 或 (`isElectron` 且存在 `app-update.yml`) |

當 `needsLock` 爲 `true` 時，AppPorts 在遷移完成後對外部存儲上的應用執行 `chflags -R uchg`（設置不可變標誌），防止自更新程序刪除或修改外部副本。

## 自定義更新器檢測 <a href="#自定義更新器檢測" id="自定義更新器檢測"></a>

對於非 Sparkle、非 Electron 的原生自更新應用（如 Chrome、Edge、Parallels），AppPorts 通過以下模式識別：

| 檢測路徑 | 匹配模式 | 典型應用 |
|----------|----------|----------|
| `Contents/Library/LaunchServices/` | 文件名包含 `update` | Chrome、Edge、Thunderbird |
| `Contents/MacOS/` | 二進制文件名包含 `update` 或 `upgrade`（排除 `electron`） | Parallels、Thunderbird |
| `Contents/SharedSupport/` | 文件名包含 `update` | WPS Office |
| `Contents/Info.plist` | 存在 `KSProductID` 鍵 | Google Keystone（Chrome） |

## 遺留策略識別 <a href="#遺留策略識別" id="遺留策略識別"></a>

在還原或解除鏈接時，AppPorts 需要識別舊版本創建的遺留入口：

| 本地結構特徵 | 識別爲 |
|-------------|--------|
| 根路徑爲符號鏈接 | `wholeAppSymlink` |
| `Contents/` 爲符號鏈接 | `deepContentsWrapper` |
| `Contents/Info.plist` 爲符號鏈接 | `wholeAppSymlink`（遺留 Sparkle 混合方案） |
| `Contents/Frameworks/` 爲符號鏈接 | `wholeAppSymlink`（遺留 Electron 混合方案） |
| `Contents/MacOS/launcher` 存在 | `stubPortal` |
| 以上均不匹配 | 非 AppPorts 管理的應用 |
