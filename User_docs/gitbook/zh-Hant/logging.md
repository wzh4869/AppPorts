---
icon: "file-lines"
layout:
  width: "default"
  outline:
    visible: true
---

# 日誌與診斷

AppPorts 內建日誌系統，用於記錄應用程式執行期間的關鍵事件、遷移操作、系統資訊和錯誤詳情。遇到問題時，可匯出診斷包並提交至專案 [Issues](https://github.com/wzh4869/AppPorts/issues)，以協助排查。

## 日誌記錄內容 <a href="#日誌記錄內容" id="日誌記錄內容"></a>

### 啟動工作階段資訊 <a href="#啟動工作階段資訊" id="啟動工作階段資訊"></a>

每次啟動 AppPorts 時，日誌會記錄以下資訊：

| 項目 | 說明 |
|------|------|
| 工作階段 ID | 本次執行的唯一識別碼（8 位 UUID 字首） |
| 行程 ID | 系統行程識別碼 |
| Bundle ID | 應用程式識別碼 |
| 應用程式語言 | 目前選擇的語言代碼 |
| 系統地區 | 系統地區設定識別碼 |
| 時區 | 目前時區識別碼 |
| 首選語言清單 | 系統首選語言順序 |

### 系統診斷資訊 <a href="#系統診斷資訊" id="系統診斷資訊"></a>

| 項目 | 說明 |
|------|------|
| 應用程式版本 | 版本號與建置編號 |
| macOS 版本 | 系統版本及產品名稱（如 "macOS Sequoia 15.x"） |
| 裝置型號 | 型號及易讀的產品名稱（如 "MacBook Pro (14-inch, M3 Pro, 2023)"） |
| 處理器資訊 | 品牌字串、核心數、使用中的核心數 |
| 實體記憶體 | 記憶體總量 |

### 外接儲存裝置資訊 <a href="#外接儲存裝置資訊" id="外接儲存裝置資訊"></a>

選擇外接儲存裝置卷宗時，日誌會記錄以下資訊：

| 項目 | 說明 |
|------|------|
| 卷宗名稱 | 儲存卷宗名稱 |
| 總容量 / 可用空間 | 儲存空間資訊 |
| 檔案系統格式 | 如 APFS、HFS+、exFAT 等 |
| 介面協定 | USB、Thunderbolt、NVMe/SATA |
| 裝置速度 | 傳輸速率資訊 |
| 區塊大小 | 儲存區塊大小 |
| 卷宗 UUID | 儲存卷宗唯一識別碼 |

### 遷移操作事件 <a href="#遷移操作事件" id="遷移操作事件"></a>

每次遷移操作都會產生唯一的操作 ID（如 `data-migrate-ABCD1234`），並記錄：

- 操作開始與結束。
- 每個步驟的進度，包括複製、刪除原始目錄、建立符號連結和回復。
- 步驟前後的路徑狀態快照，包括存在性、權限、大小、符號連結目標和不可變標誌。
- 殘留遷移資料偵測與自動恢復。
- 檔案複製進度、錯誤與重試。

### 遷移效能報告 <a href="#遷移效能報告" id="遷移效能報告"></a>

| 項目 | 說明 |
|------|------|
| 應用程式名稱 | 遷移的應用程式名 |
| 資料大小 | 遷移資料量 |
| 耗時 | 遷移持續時間（秒） |
| 傳輸速度 | 傳輸速率（MB/s） |
| 來源路徑 / 目標路徑 | 遷移起止路徑 |

### 錯誤詳情 <a href="#錯誤詳情" id="錯誤詳情"></a>

錯誤日誌會包含結構化資訊：

| 欄位 | 說明 |
|------|------|
| 錯誤描述 | 人類可讀的錯誤說明 |
| 錯誤類型 / 領域 / 代碼 | NSError 結構化資訊 |
| 錯誤碼 | AppPorts 內部錯誤碼（見下表） |
| 失敗原因 | 詳細失敗原因 |
| 恢復建議 | 系統提供的恢復建議 |
| 檔案路徑 | 涉及的檔案路徑 |
| 關聯路徑 | 操作涉及的相關應用程式路徑（`relatedURLs`） |
| 底層錯誤 | 巢狀錯誤遞迴記錄 |

### 錯誤碼 <a href="#錯誤碼" id="錯誤碼"></a>

| 錯誤碼 | 意義 |
|--------|------|
| `BACKUP-SIGNATURE-FAILED` | 簽名備份失敗 |
| `APP-MOVE-DESTINATION-CONFLICT` | 應用程式遷移目標已存在，且不能確認可安全替換 |
| `APP-RESTORE-LOCAL-CONFLICT` | 遷回本機時發現無法自動覆蓋的本機同名項目 |
| `DATA-MIGRATE-DESTINATION-CONFLICT` | 資料目錄遷移目標已存在，且 metadata 未完全相符 |
| `RESIGN-FAILED` | 重簽名失敗（應用程式可能無法通過 macOS 簽名驗證） |
| `DATA-RESIGN-FAILED` | 資料目錄遷移後自動重簽名失敗 |
| `RESIGN-REFUSED-SANDBOXED` | 拒絕對沙盒應用程式重簽名 |
| `RESTORE-SIGNATURE-IDENTITY-UNAVAILABLE` | 原始簽名憑證不在本機，拒絕恢復 |
| `CONTAINER-MOUNT-*` | 掛載遷移各階段失敗，如 `CONTAINER-MOUNT-EXTERNAL-NOT-APFS`、`CONTAINER-MOUNT-SWITCH-FAILED` |
| `CONTAINER-RESTORE-*` | 掛載遷移目錄還原各階段失敗 |
| `DATA-BACKUP-SIGNATURE-FAILED` | 資料目錄遷移前簽名備份失敗（後續恢復簽名將無法使用原始身分） |

### 資料目錄操作脈絡 <a href="#資料目錄操作脈絡" id="資料目錄操作脈絡"></a>

資料目錄操作（遷移、恢復、正規化、重新連結）的日誌會自動包含相關應用程式的背景資訊：

| 欄位 | 說明 |
|------|------|
| `app_name` | 關聯應用程式名稱 |
| `app_status` | 應用程式狀態（已連結、本地等） |
| `app_is_resigned` | 應用程式是否已被重簽名 |
| `app_bundle_id` | 應用程式的 Bundle ID（基於真實路徑讀取） |
| `app_real_path` | 應用程式的真實外部路徑 |

### 操作摘要 <a href="#操作摘要" id="操作摘要"></a>

每個遷移操作產生 `OperationSummaryRecord` 記錄，保留最近 100 條：

| 欄位 | 說明 |
|------|------|
| `operationID` | 操作唯一識別碼 |
| `category` | 操作類別（`app_move`、`data-migrate`、`file-copy` 等） |
| `result` | 結果（`success`、`failed`、`rolled_back`、`success_with_warning`） |
| `errorCode` | 錯誤碼（如有） |
| `startedAt` / `endedAt` | 起止時間 |
| `durationMs` | 耗時（毫秒） |

## 日誌設定 <a href="#日誌設定" id="日誌設定"></a>

### 儲存位置 <a href="#儲存位置" id="儲存位置"></a>

預設日誌路徑：

```text
~/Library/Application Support/AppPorts/AppPorts_Log.txt
```

可透過以下方式自訂日誌位置：

- 選單欄 →「日誌」→「設定日誌位置...」。
- 設定 → 日誌設定 → 自訂路徑。

### 日誌格式 <a href="#日誌格式" id="日誌格式"></a>

```text
[2026-05-08 09:30:00] [INFO] [session:a1b2c3d4] [pid:12345] 应用启动
[2026-05-08 09:30:01] [DIAG] [session:a1b2c3d4] [pid:12345]   app_version: 1.6.1 (123)
[2026-05-08 09:30:05] [PERF] [session:a1b2c3d4] [pid:12345]   迁移完成: 2.3 GB, 45.2 MB/s, 52.1s
```

### 日誌層級 <a href="#日誌層級" id="日誌層級"></a>

| 層級 | 說明 |
|------|------|
| `INFO` | 一般資訊 |
| `ERROR` | 錯誤資訊（含結構化錯誤詳情） |
| `DIAG` | 系統診斷資訊 |
| `DISK` | 外接儲存裝置卷宗資訊 |
| `PERF` | 遷移效能報告 |
| `TRACE` | 底層路徑狀態與資料夾監控 |
| `DEBUG` | 除錯資訊（大小計算、巢狀目錄檢查） |
| `WARN` | 警告（殘留遷移資料、恢復模式） |

### 日誌輪替 <a href="#日誌輪替" id="日誌輪替"></a>

- 預設最大大小：**2 MB**（可設定為 1 MB、5 MB、10 MB、50 MB 或 100 MB）。
- 超出限制時自動截斷：丟棄較舊的一半行，保留較新的一半。

## 匯出診斷包 <a href="#匯出診斷包" id="匯出診斷包"></a>

當遇到問題需要回報時，請匯出診斷包並附帶在 Issue 中。

### 匯出方式 <a href="#匯出方式" id="匯出方式"></a>

**方式一：選單欄**

1. 按一下選單欄 → 日誌 → 匯出診斷包。
2. 選擇儲存位置。
3. 系統會自動產生 `.zip` 檔案，並在 Finder 中開啟。

**方式二：設定頁面**

1. 開啟 AppPorts → 右上角設定。
2. 找到「日誌設定」區域。
3. 按一下「匯出診斷包」按鈕。
4. 選擇儲存位置。

### 診斷包內容 <a href="#診斷包內容" id="診斷包內容"></a>

匯出的 `AppPorts-Diagnostic-<日期时间>.zip` 包含：

| 檔案 | 格式 | 說明 |
|------|------|------|
| `diagnostic-summary.json` | JSON | 後設資料（工作階段 ID、版本、區域、時區等） |
| `diagnostic-summary.txt` | 純文字 | 人類可讀的診斷摘要 |
| `recent-operations.json` | JSON | 最近 100 條操作記錄 |
| `recent-failures.json` | JSON | 最近 20 條失敗/警告操作 |
| `AppPorts_Log.share-safe.txt` | 純文字 | 完整日誌（已隱去敏感資訊） |

### 隱私保護 <a href="#隱私保護" id="隱私保護"></a>

診斷包中的日誌檔案已隱去敏感資訊：

| 原始內容 | 替換為 |
|----------|--------|
| 使用者主目錄路徑（如 `/Users/john`） | `/Users/<redacted-user>` |
| 外接儲存裝置卷宗名稱（如 `/Volumes/MyDrive`） | `/Volumes/<redacted-volume>` |
| `$HOME` 完整路徑 | `~` |

## 提交 Issue <a href="#提交-issue" id="提交-issue"></a>

取得診斷包後，請按以下步驟提交：

1. 開啟專案 [Issues](https://github.com/wzh4869/AppPorts/issues) 頁面。
2. 按一下「New Issue」，選擇 Bug 回報範本。
3. 描述問題現象和重現步驟。
4. 將診斷包 `.zip` 檔案拖移至附件區域上傳。
5. 提交 Issue。

{% hint style="success" %}
**提高回報效率**

提交 Issue 時附帶診斷包，可顯著加快問題定位速度。診斷包包含完整的操作歷史、錯誤詳情和系統環境資訊，開發者無需反覆溝通即可重現和分析問題。
{% endhint %}
