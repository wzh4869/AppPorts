---
outline: deep
---

# 貢獻者指南

感謝你關注 AppPorts！我們歡迎社群成員參與貢獻，無論是修復 Bug、改進文件，還是新增新功能。

## 開始之前 {#section-1}

1. 搜尋現有的 [Issues](https://github.com/wzh4869/AppPorts/issues)，確認沒有相關的重複議題。
   重要功能的變更請先透過 [Issue](https://github.com/wzh4869/AppPorts/issues) 討論，或加入 [QQ群 (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) 與群主討論；群內討論後，由群主在 Issue 公開討論結論。
2. Fork 專案並克隆到本地。
3. 基於 `main` 分支建立功能分支（`feat/your-feature`）或修復分支（`fix/your-fix`）。

- 應用程式支援 macOS 12 及以上；這不是開發環境的最低版本。開發需要完整 Xcode（僅安裝 Command Line Tools 不夠），測試工具鏈還須支援 Swift Testing。優先使用與目前 CI 一致的 Xcode；具體版本可從 Actions 的 Build environment 記錄查看，儲存庫尚未宣告經過驗證的最低 Xcode 版本。
- 在 Xcode 中開啟 `AppPorts.xcodeproj`，選擇共用的 `AppPorts` scheme 與 My Mac。應用程式不使用 Swift Package Manager，也沒有第三方 Swift 相依套件。命令列驗證使用下文的無簽章參數，無須設定發佈憑證；在本機執行時依實際操作授予所需權限。
- 先用 `xcodebuild -version` 檢查目前工具鏈。Xcode 不在預設位置時，在目前終端機設定 `DEVELOPER_DIR`，例如：

```bash
export DEVELOPER_DIR="/Volumes/<external-volume>/Applications/Xcode.app/Contents/Developer"
```

## 開發方式 {#section-2}

### 關於 Vibe Coding {#section-3}

AppPorts 專案接受使用 AI 輔助工具（如 Cursor、GitHub Copilot、Claude 等）進行 Vibe Coding 開發。AI 工具可以顯著提高開發效率，**但提交程式碼的質量和正確性仍由貢獻者本人負責**。

使用 Vibe Coding 時請注意：

- **AI 助手必須遵循專案根目錄的 `CLAUDE.md`**。該檔案定義了編碼準則、安全邊界、構建命令和開發流程。如 AI 助手未自動讀取該檔案，請在提示詞中明確要求模型先閱讀 `CLAUDE.md`。
- AI 生成的程式碼可能不符合專案既有風格，提交前請進行人工審查。
- AI 無法替代對 macOS 系統行為的理解。涉及檔案系統操作、程式碼簽章、權限管理等邏輯時，請務必手動驗證。
- **核心功能**（如遷移策略、資料目錄遷移、程式碼簽章等）的變更同樣遵循上述討論流程，獲得確認後再執行開發。

### 程式碼規範 {#section-4}

- 遵循 Swift 程式碼規範和專案既有風格。
- 為複雜邏輯編寫清晰的 Swift 文件註釋。
- SwiftUI 字面量使用 `LocalizedStringKey` API；AppKit/API 字串使用 `.localized`。

## 測試要求 {#section-5}

::: warning PR 必須通過 Release 編譯
CI 強制編譯煙霧檢查；專項測試提供 Advisory 回饋，不作為 PR 的自動合併門檻。
:::

**區分合併門檻與驗證責任：** PR 的自動合併門檻仍是 Release 編譯；建議外部貢獻者執行受影響模組的測試，並在 PR 中如實記錄通過、失敗、略過或未執行及原因。AI 助手還必須遵循 `CLAUDE.md`：修改已有測試涵蓋的模組時執行對應測試。Advisory 表示 CI 不阻擋合併，不表示可以忽略失敗；需要說明失敗是否與本次變更有關。

完整測試在可拋棄的 macOS runner 上執行；部分整合測試會將暫存應用程式註冊到 Launch Services。不要用 `sudo` 執行測試，也不要在 CI 中設定 `APPPORTS_TEST_EXTERNAL_ROOT` 或 `APPPORTS_RENDER_UI_OUTPUT`。實體外接磁碟實驗應使用專用測試資料，並與預設自動測試區分。

### 必須通過：編譯煙霧檢查 {#section-6}

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

### 按需執行：專項測試 {#section-7}

當 PR 涉及對應模組時，建議主動補跑以下專項測試。CI 也會在 PR 中以 Advisory 模式執行，結果不阻塞合併，但會提供反饋。

#### 資料目錄測試 {#section-8}

當 PR 涉及 `DataDirMover`、`DataDirScanner` 或資料目錄遷移相關邏輯時執行：

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

#### 應用遷移測試 {#section-9}

當 PR 涉及 `AppMigrationService`、`AppScanner` 或應用遷移邏輯時執行：

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

#### 日誌測試 {#section-10}

當 PR 涉及 `AppLogger` 或診斷功能時執行：

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

#### 本地化審計 {#section-11}

當 PR 涉及使用者可見文案、選單、彈窗、設定項、錯誤提示時執行：

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

### 測試總覽 {#section-12}

| 測試套件 | 涉及模組 | 執行時機 |
|----------|----------|----------|
| 編譯煙霧檢查 | 全專案 | **必須**（CI 強制） |
| `DataDirMoverTests` | 資料目錄遷移 | 涉及 `DataDirMover` 時 |
| `DataDirScannerTests` | 資料目錄掃描 | 涉及 `DataDirScanner` 時 |
| `AppMigrationServiceTests` | 應用遷移 | 涉及 `AppMigrationService` 時 |
| `AppScannerTests` | 應用掃描 | 涉及 `AppScanner` 時 |
| `AppLoggerTests` | 日誌與診斷 | 涉及 `AppLogger` 時 |
| `LocalizationAuditTests` | 本地化 | 涉及使用者可見文案時 |

其他變更的測試入口（並非完整清單，須配合呼叫端選擇）：

| 變更領域 | 測試入口 |
| --- | --- |
| 自選資料夾 | `CustomDirScannerTests`、`CustomDirRecoveryEligibilityTests` |
| 檔案複製與擁有權 | `FileCopierTests`、`TreeCopySessionTests`、`TreeCopyOwnershipTests` |
| 容器掛載遷移 | `ContainerVolumeMigratorTests`、`ContainerMountSafetyTests` |
| 簽章操作與修復 | `CodeSignerTests`、`SignatureOperationTests`、`SignatureRepairSafetyTests` |
| 遷移記錄與復原 | `DataTransferStoreTests`、`DataTransferRecoveryTests`、`AppTransferTransactionTests` |
| 操作狀態與 Dock | `AppOperationStateTests`、`DockShortcutServiceTests` |
| 子程序期限 | `ProcessCommandRunnerTests`（獨立執行） |
| 更新與贊助名單 | `UpdateCheckerTests`、`SponsorsTests` |

CI 在一次 Debug 測試編譯後分應用程式回歸、程序計時、本地化三步執行完整測試。PR 中均為 Advisory；合併到 `main` 後應用程式回歸與程序計時必須通過，本地化仍為 Advisory，隨後編譯 Release 並驗證、上傳未簽章應用程式封裝。綠色 Advisory 工作不保證全部測試通過，請閱讀步驟摘要；記錄與 `.xcresult` 保留 5 天。同一 PR 的新提交會取消舊檢查。

CI 的完整命令見[共用指令碼](https://github.com/wzh4869/AppPorts/blob/main/.github/scripts/run-xcode-check.sh)：`prepare-tests` 後依序執行 `regression`、`process`、`localization`，共用同一 runner 與 DerivedData；`release` 執行 Release clean build。呼叫前設定 `CI_DERIVED_DATA_PATH` 與 `CI_RESULTS_DIR` 為本次驗證專用目錄，重複執行使用新的結果目錄，避免既有 `.xcresult` 衝突。修改共用複製、掃描或傳輸基礎邏輯後，推進 `main` 前還須依 `CLAUDE.md` 完成隔離 runner 的完整驗證。

## 本地化 {#section-13}

- 外部貢獻者可以在 PR 中延後完整翻譯，但程式碼仍須正確接入本地化：新增 key 加入 `AppPorts/Localizable.xcstrings`，AppKit/API 文案使用 `.localized`，動態文案使用格式化 key，語言列表來自 `AppLanguageCatalog`。
- 未完成翻譯時，在 PR 中列出受影響文案、語言、實際備援顯示與後續計畫；不要複製英文、刪除稽核斷言或擴大豁免名單來掩蓋缺譯。AI 助手依 `CLAUDE.md` 與維護者確認本次翻譯範圍。
- 字串目錄只修改相關 key 與譯文，避免夾帶整份目錄重排。選單、對話框、設定、錯誤、狀態與 onboarding 文案變更後，建議檢查 `zh-Hans` 與 `en` 的實際顯示。

更多規則見：[LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Commit 規範 {#section-14}

- 重要功能的變更請先透過 [Issue](https://github.com/wzh4869/AppPorts/issues) 討論，或加入 [QQ群 (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) 與群主討論；群內討論後，由群主在 Issue 公開討論結論。
- **保持原子化**：每個 PR 儘量只解決一個問題或新增一個功能
- **Commit 資訊建議**：
  - `feat: ...` — 新功能
  - `fix: ...` — 修復 Bug
  - `docs: ...` — 文件更新
  - `refactor: ...` — 重構
  - `test: ...` — 測試相關

**決策筆記：** 非平凡變更（行為、架構、跨檔案契約、流程工具、測試策略或儲存格式）須隨程式碼在同一 commit / PR 中提交決策筆記。先搜尋 `.agents/notes/` 的既有決定；已有歸屬的事實更新原筆記，新的取捨依[儲存庫內技能](https://github.com/wzh4869/AppPorts/blob/main/.claude/skills/write-notes-like-deepseek/SKILL.md)處理。純機械變更免寫。筆記只放 `.agents/notes/`，不放 `User_docs`；格式、生命週期與三項驗證命令以該技能為準。PR 中附筆記連結，或說明不適用原因。

## 提交 PR {#section-15}

1. 確保分支基於最新的 `main` 分支。
2. 推送到你的 Fork 倉庫。
3. 向 AppPorts 的 `main` 分支提交 Pull Request。
4. 填寫 PR 模板中的必填項。
5. 等待 CI 檢查通過和 Code Review。

::: tip 提高合併效率
- 保持每個 PR 聚焦於單一問題或功能。
- 如實填寫 PR 模板中的測試情況。
- 涉及 UI 變更時附上截圖。
:::

根目錄 [CONTRIBUTING.md](https://github.com/wzh4869/AppPorts/blob/main/CONTRIBUTING.md) 是貢獻流程入口；修改共用規則時同步根目錄中英文、文件站簡中/繁中/英文指南及受影響的 PR 範本。AI 執行規則以 `AGENTS.md` / `CLAUDE.md` 為準，文件站操作細節以 `User_docs/README.md` 為準，筆記規範以儲存庫內技能為準。

## 歡迎的貢獻方向 {#section-16}

- 針對 `AppScanner` 等核心邏輯的穩定性和效能改進。
- UI/UX 最佳化，特別是符合 macOS 系統原生體驗的改進。
- 簡體中文、繁體中文與英文文件的同步與完善。

僅修改文件站時，先閱讀 [User_docs/README.md](https://github.com/wzh4869/AppPorts/blob/main/User_docs/README.md) 與 [User_docs/AGENTS.md](https://github.com/wzh4869/AppPorts/blob/main/User_docs/AGENTS.md)。在 `User_docs` 下使用相容的 Node.js LTS，執行 `npm ci`、`npm run docs:dev`；編輯 Markdown 後執行 `npm run docs:prepare` 更新。提交前依序執行 `npm run docs:build`、`npm run docs:typecheck`、`npm run docs:check`。

簡中原文與繁中、英文譯文須同步，共用章節 ID 及其順序。不要編輯或提交 `.content/`、`public/`、`.next/`、`out/` 產物。檢查修改頁面的三語桌面與手機顯示；涉及站點功能時，另查搜尋、主題、語言切換及 Markdown 匯出。純文件貢獻依文件檢查驗證；應用程式原始碼變更依應用程式建置與相關測試驗證；應用程式翻譯變更依本地化稽核與顯示檢查驗證。建置不會自動發佈站點。
