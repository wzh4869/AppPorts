# Tool Directory Detection

![](https://pic.cdn.shimoko.com/tools.png)

AppPorts can automatically detect data directories (dot-folders) created by common development tools, AI tools, and editors in the user's home directory, and supports migrating them to external storage. For more tool migration requirements, please submit them to the project [Issues](https://github.com/wzh4869/AppPorts/issues).

## Priority Levels <a href="#priority-levels" id="priority-levels"></a>

| Priority | Meaning |
|----------|---------|
| `critical` | Must work after migration; affects core application functionality |
| `recommended` | Large space savings; high migration benefit |
| `optional` | Small size or rebuildable |

## Development Tools / Package Managers <a href="#development-tools-package-managers" id="development-tools-package-managers"></a>

| Tool | Path | Priority | Description |
|------|------|----------|-------------|
| npm | `~/.npm` | recommended | Node.js package manager local cache |
| Maven | `~/.m2` | recommended | Java Maven dependency repository |
| Gradle | `~/.gradle` | recommended | Gradle build cache, Wrapper, and dependency data |
| Android Development Data | `~/.android` | recommended | Android, ADB, and emulator configuration and cache data |
| Flutter/Dart Pub | `~/.pub-cache` | recommended | Dart and Flutter Pub package cache |
| Bun | `~/.bun` | recommended | Bun JavaScript runtime and cache |
| Conda | `~/.conda` | recommended | Anaconda/Miniconda environment data |
| Composer | `~/.composer` | optional | PHP Composer global packages |
| Nexus | `~/.nexus` | optional | Nexus proxy cache |

## AI / Machine Learning Tools <a href="#ai-machine-learning-tools" id="ai-machine-learning-tools"></a>

| Tool | Path | Priority | Description |
|------|------|----------|-------------|
| Ollama | `~/.ollama` | recommended | Local large language model storage |
| PyTorch | `~/.cache/torch` | recommended | Pre-trained model weights cache |
| Whisper | `~/.cache/whisper` | recommended | OpenAI speech recognition models |
| Keras | `~/.keras` | optional | Keras models and datasets |
| NLTK | `~/nltk_data` | optional | Natural language processing corpora |

## AI Coding Assistants <a href="#ai-coding-assistants" id="ai-coding-assistants"></a>

| Tool | Path | Priority | Description |
|------|------|----------|-------------|
| Lingma | `~/.lingma` | optional | Alibaba Cloud AI coding assistant |
| Trae IDE | `~/.trae` | optional | ByteDance Trae IDE |
| Trae CN | `~/.trae-cn` | optional | Trae IDE domestic version |
| Trae AICC | `~/.trae-aicc` | optional | Trae AICC |
| MarsCode | `~/.marscode` | optional | ByteDance MarsCode IDE |
| CodeBuddy | `~/.codebuddy` | optional | Tencent AI assistant |
| CodeBuddy CN | `~/.codebuddycn` | optional | Tencent CodeBuddy domestic version |
| Qwen | `~/.qwen` | optional | Alibaba Tongyi Qianwen |
| ClawBOT | `~/.clawdbot` | optional | ClawdBOT AI tool |

## Editors / IDEs <a href="#editors-ides" id="editors-ides"></a>

| Tool | Path | Priority | Description |
|------|------|----------|-------------|
| VS Code | `~/.vscode` | optional | Extensions and configuration |
| Cursor | `~/.cursor` | optional | Cursor AI editor |
| Spring Tool Suite 4 | `~/.sts4` | optional | STS4 data |

## Browsers / Test Automation <a href="#browsers-test-automation" id="browsers-test-automation"></a>

| Tool | Path | Priority | Description |
|------|------|----------|-------------|
| Selenium | `~/.cache/selenium` | optional | Auto-downloaded browser drivers |
| Chromium | `~/.chromium-browser-snapshots` | optional | Browser snapshots used by Playwright/Selenium |
| WDM | `~/.wdm` | optional | WebDriver Manager driver programs |

## Runtime Environments <a href="#runtime-environments" id="runtime-environments"></a>

| Tool | Path | Priority | Description |
|------|------|----------|-------------|
| Docker | `~/.docker` | optional | Docker Desktop CLI configuration and context |
| OpenClaw | `~/.openclaw` | optional | OpenClaw tool data |

## Non-migratable System Directories <a href="#non-migratable-system-directories" id="non-migratable-system-directories"></a>

The following directories contain absolute path references or executable files; migrating them may cause tool failures. **Migration is not supported**:

| Path | Reason |
|------|--------|
| `~/.local` | Contains executable path references; command-line tools may fail after migration |
| `~/.config` | Contains absolute path configurations; tool configurations may fail after migration |

## Conda Distribution Special Handling <a href="#conda-distribution-special-handling" id="conda-distribution-special-handling"></a>

When an app's Bundle ID or name contains `anaconda`, `conda`, or `miniconda`, AppPorts additionally scans the following paths to identify the Conda installation root:

- `/opt/anaconda3`
- `/opt/miniconda3`
- `/usr/local/anaconda3`
- `/usr/local/miniconda3`
- `~/anaconda3`
- `~/miniconda3`
