# 工具目錄識別
![](https://pic.cdn.shimoko.com/tools.png)
AppPorts 可自動識別常見開發工具、AI 工具、編輯器等在用戶目錄下創建的數據目錄（dot-folder），並支持將其遷移至外部存儲，如有對更多工具的遷移需求，請提交至項目 [Issues](https://github.com/wzh4869/AppPorts/issues)。

## 優先級說明 <a href="#優先級說明" id="優先級說明"></a>

| 優先級 | 含義 |
|--------|------|
| `critical` | 遷移後必須正常工作，影響應用核心功能 |
| `recommended` | 佔用空間大，遷移收益高 |
| `optional` | 空間較小或可重建 |

## 開發工具 / 包管理器 <a href="#開發工具-包管理器" id="開發工具-包管理器"></a>

| 工具 | 路徑 | 優先級 | 說明 |
|------|------|--------|------|
| npm | `~/.npm` | recommended | Node.js 包管理器本地緩存 |
| Maven | `~/.m2` | recommended | Java Maven 依賴倉庫 |
| Gradle | `~/.gradle` | recommended | Gradle 構建緩存、Wrapper 和依賴數據 |
| Android 開發數據 | `~/.android` | recommended | Android、ADB 和模擬器配置與緩存數據 |
| Flutter/Dart Pub | `~/.pub-cache` | recommended | Dart 和 Flutter Pub 包緩存 |
| Bun | `~/.bun` | recommended | Bun JavaScript 運行時及緩存 |
| Conda | `~/.conda` | recommended | Anaconda/Miniconda 環境數據 |
| Composer | `~/.composer` | optional | PHP Composer 全局包 |
| Nexus | `~/.nexus` | optional | Nexus 代理緩存 |

## AI / 機器學習工具 <a href="#ai-機器學習工具" id="ai-機器學習工具"></a>

| 工具 | 路徑 | 優先級 | 說明 |
|------|------|--------|------|
| Ollama | `~/.ollama` | recommended | 本地大語言模型存儲 |
| PyTorch | `~/.cache/torch` | recommended | 預訓練模型權重緩存 |
| Whisper | `~/.cache/whisper` | recommended | OpenAI 語音識別模型 |
| Keras | `~/.keras` | optional | Keras 模型和數據集 |
| NLTK | `~/nltk_data` | optional | 自然語言處理語料庫 |

## AI 編程助手 <a href="#ai-編程助手" id="ai-編程助手"></a>

| 工具 | 路徑 | 優先級 | 說明 |
|------|------|--------|------|
| 靈碼（Lingma） | `~/.lingma` | optional | 阿里雲 AI 編程助手 |
| Trae IDE | `~/.trae` | optional | 字節跳動 Trae IDE |
| Trae CN | `~/.trae-cn` | optional | Trae IDE 國內版 |
| Trae AICC | `~/.trae-aicc` | optional | Trae AICC |
| MarsCode | `~/.marscode` | optional | 字節跳動 MarsCode IDE |
| CodeBuddy | `~/.codebuddy` | optional | 騰訊 AI 助手 |
| CodeBuddy CN | `~/.codebuddycn` | optional | 騰訊 CodeBuddy 國內版 |
| Qwen | `~/.qwen` | optional | 阿里通義千問 |
| ClawBOT | `~/.clawdbot` | optional | ClawdBOT AI 工具 |

## 編輯器 / IDE <a href="#編輯器-ide" id="編輯器-ide"></a>

| 工具 | 路徑 | 優先級 | 說明 |
|------|------|--------|------|
| VS Code | `~/.vscode` | optional | 擴展及配置 |
| Cursor | `~/.cursor` | optional | Cursor AI 編輯器 |
| Spring Tool Suite 4 | `~/.sts4` | optional | STS4 數據 |

## 瀏覽器 / 測試自動化 <a href="#瀏覽器-測試自動化" id="瀏覽器-測試自動化"></a>

| 工具 | 路徑 | 優先級 | 說明 |
|------|------|--------|------|
| Selenium | `~/.cache/selenium` | optional | 自動下載的瀏覽器驅動 |
| Chromium | `~/.chromium-browser-snapshots` | optional | Playwright/Selenium 使用的瀏覽器快照 |
| WDM | `~/.wdm` | optional | WebDriver Manager 驅動程序 |

## 運行時環境 <a href="#運行時環境" id="運行時環境"></a>

| 工具 | 路徑 | 優先級 | 說明 |
|------|------|--------|------|
| Docker | `~/.docker` | optional | Docker Desktop CLI 配置和上下文 |
| OpenClaw | `~/.openclaw` | optional | OpenClaw 工具數據 |

## 不可遷移的系統目錄 <a href="#不可遷移的系統目錄" id="不可遷移的系統目錄"></a>

以下目錄因包含絕對路徑引用或可執行文件，整體遷移可能導致工具失效，**不支持遷移**：

| 路徑 | 原因 |
|------|------|
| `~/.local` | 包含可執行文件路徑引用，遷移後命令行工具可能失效 |
| `~/.config` | 包含絕對路徑配置，遷移後工具配置可能失效 |

## Conda 發行版特殊處理 <a href="#conda-發行版特殊處理" id="conda-發行版特殊處理"></a>

當應用的 Bundle ID 或名稱包含 `anaconda`、`conda` 或 `miniconda` 時，AppPorts 會額外掃描以下路徑以識別 Conda 安裝根目錄：

- `/opt/anaconda3`
- `/opt/miniconda3`
- `/usr/local/anaconda3`
- `/usr/local/miniconda3`
- `~/anaconda3`
- `~/miniconda3`
