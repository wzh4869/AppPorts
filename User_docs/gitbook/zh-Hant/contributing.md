---
icon: "code-pull-request"
layout:
  width: "default"
  outline:
    visible: true
---

# 貢獻者指南

感謝你關注 AppPorts！我們歡迎社區成員參與貢獻，無論是修復 Bug、改進文檔還是添加新功能。

## 開始之前 <a href="#開始之前" id="開始之前"></a>

1. 搜索現有的 [Issues](https://github.com/wzh4869/AppPorts/issues)，確認沒有相關的重複議題
2. Fork 項目並克隆到本地
3. 基於 `develop` 分支創建功能分支（`feat/your-feature`）或修復分支（`fix/your-fix`）

## 開發方式 <a href="#開發方式" id="開發方式"></a>

### 關於 Vibe Coding <a href="#關於-vibe-coding" id="關於-vibe-coding"></a>

AppPorts 項目接受使用 AI 輔助工具（如 Cursor、GitHub Copilot、Claude 等）進行 Vibe Coding 開發。我們理解 AI 工具可以顯著提高開發效率，**但提交代碼的質量和正確性由貢獻者本人負責**。

使用 Vibe Coding 時請注意：

- **AI 助手必須遵循項目根目錄的 `CLAUDE.md`**，該文件定義了編碼準則、架構規範、構建命令和開發流程。如 AI 助手未自動讀取該文件，請在提示詞中明確要求模型先閱讀 `CLAUDE.md`
- 建議通過多個 AI 模型交叉驗證生成代碼的質量與安全性，避免單一模型的盲區
- AI 生成的代碼可能不符合項目既有風格，提交前請進行人工審查
- AI 無法替代對 macOS 系統行爲的理解，涉及文件系統操作、代碼簽名、權限管理等邏輯時請務必手動驗證
- **核心功能**（如遷移策略、數據目錄遷移、代碼簽名等）的變更必須先提交 Issue 討論，獲得確認後再執行開發

### 代碼規範 <a href="#代碼規範" id="代碼規範"></a>

- 遵循 Swift 代碼規範和項目既有風格
- 爲複雜的邏輯編寫清晰的 Swift 文檔註釋
- SwiftUI 字面量使用 `LocalizedStringKey` API；AppKit/API 字符串使用 `.localized`

## 測試要求 <a href="#測試要求" id="測試要求"></a>

{% hint style="warning" %}
**⚠️ 所有 PR 必須通過測試**

無論使用何種開發方式，提交 PR 前必須完成以下測試。CI 會自動運行編譯煙霧檢查，未通過的 PR 將被阻止合併。
{% endhint %}

### 必須通過：編譯煙霧檢查 <a href="#必須通過-編譯煙霧檢查" id="必須通過-編譯煙霧檢查"></a>

所有 PR 必須通過 Xcode Release 編譯，這是合併的硬性門檻：

```bash
xcodebuild clean build \
  -scheme "AppPorts" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### 按需運行：專項測試 <a href="#按需運行-專項測試" id="按需運行-專項測試"></a>

當 PR 涉及對應模塊時，建議主動補跑以下專項測試。CI 也會在 PR 中以 Advisory 模式運行，結果不阻塞合併但會提供反饋。

#### 數據目錄測試 <a href="#數據目錄測試" id="數據目錄測試"></a>

當 PR 涉及 `DataDirMover`、`DataDirScanner` 或數據目錄遷移相關邏輯時運行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/DataDirMoverTests" \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 應用遷移測試 <a href="#應用遷移測試" id="應用遷移測試"></a>

當 PR 涉及 `AppMigrationService`、`AppScanner` 或應用遷移邏輯時運行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppMigrationServiceTests" \
  -only-testing:"AppPortsTests/AppScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 日誌測試 <a href="#日誌測試" id="日誌測試"></a>

當 PR 涉及 `AppLogger` 或診斷功能時運行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppLoggerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 本地化審計 <a href="#本地化審計" id="本地化審計"></a>

當 PR 涉及用戶可見文案、菜單、彈窗、設置項、錯誤提示時運行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### 測試總覽 <a href="#測試總覽" id="測試總覽"></a>

| 測試套件 | 涉及模塊 | 運行時機 |
|----------|----------|----------|
| 編譯煙霧檢查 | 全項目 | **必須**（CI 強制） |
| `DataDirMoverTests` | 數據目錄遷移 | 涉及 `DataDirMover` 時 |
| `DataDirScannerTests` | 數據目錄掃描 | 涉及 `DataDirScanner` 時 |
| `AppMigrationServiceTests` | 應用遷移 | 涉及 `AppMigrationService` 時 |
| `AppScannerTests` | 應用掃描 | 涉及 `AppScanner` 時 |
| `AppLoggerTests` | 日誌與診斷 | 涉及 `AppLogger` 時 |
| `LocalizationAuditTests` | 本地化 | 涉及用戶可見文案時 |

## 本地化 <a href="#本地化" id="本地化"></a>

- 本地化適配是推薦項，不作爲外部貢獻者提交 PR 的強制門檻
- 如 PR 新增、修改或刪除了用戶可見文案，歡迎在同一個 PR 中同步更新 `Localizable.xcstrings`
- 如本次暫不處理，請在 PR 說明中簡要說明原因或後續計劃
- SwiftUI 字面量使用 `LocalizedStringKey` API；AppKit/API 字符串使用 `.localized`
- 動態文案建議使用格式化 key，如 `String(format: "排序：%@".localized, value)`
- 語言列表統一維護在 `AppLanguageCatalog`，不要在多個頁面重複硬編碼
- 如 PR 變更了菜單、彈窗、設置項、日誌導出、錯誤提示、狀態文案或 onboarding 文案，建議至少檢查一次 `zh-Hans` 和 `en` 的實際顯示結果

更多規則見：[LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Commit 規範 <a href="#commit-規範" id="commit-規範"></a>

- **Issue 優先**：重要功能的變更請先通過 Issue 討論
- **保持原子化**：每個 PR 儘量只解決一個問題或添加一個功能
- **Commit 信息建議**：
  - `feat: ...` — 新功能
  - `fix: ...` — 修復 Bug
  - `docs: ...` — 文檔更新
  - `refactor: ...` — 重構
  - `test: ...` — 測試相關

## 提交 PR <a href="#提交-pr" id="提交-pr"></a>

1. 確保分支基於最新的 `develop` 分支
2. 推送到你的 Fork 倉庫
3. 向 AppPorts 的 `develop` 分支提交 Pull Request
4. 填寫 PR 模板中的必填項
5. 等待 CI 檢查通過和 Code Review

{% hint style="success" %}
**💡 提高合併效率**

- 保持每個 PR 聚焦於單一問題或功能
- 如實填寫 PR 模板中的測試情況
- 涉及 UI 變更時附上截圖
{% endhint %}

## 歡迎的貢獻方向 <a href="#歡迎的貢獻方向" id="歡迎的貢獻方向"></a>

- 針對 `AppScanner` 等核心邏輯的穩定性和性能改進
- UI/UX 優化，特別是符合 macOS 系統原生感的改進
- 中英文檔的同步和完善
