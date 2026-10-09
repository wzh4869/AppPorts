---
icon: "terminal"
description: "查看工具数据目录的识别范围。"
layout:
  width: "default"
  outline:
    visible: true
---

# 工具目录识别

![](https://pic.cdn.shimoko.com/tools.png)

AppPorts 可自动识别常见开发工具、AI 工具和编辑器在用户目录下创建的数据目录（dot-folder），并支持将其迁移至外部存储。如需支持更多工具，欢迎在项目 [Issues](https://github.com/wzh4869/AppPorts/issues) 中提交需求。

## 优先级说明 <a href="#优先级说明" id="优先级说明"></a>

| 优先级 | 含义 |
|--------|------|
| `critical` | 迁移后必须保持正常工作，会影响应用核心功能 |
| `recommended` | 占用空间大，迁移收益高 |
| `optional` | 空间较小或可重建 |

## 开发工具 / 包管理器 <a href="#开发工具-包管理器" id="开发工具-包管理器"></a>

| 工具 | 路径 | 优先级 | 说明 |
|------|------|--------|------|
| npm | `~/.npm` | recommended | Node.js 包管理器本地缓存 |
| Maven | `~/.m2` | recommended | Java Maven 依赖仓库 |
| Gradle | `~/.gradle` | recommended | Gradle 构建缓存、Wrapper 和依赖数据 |
| Android 开发数据 | `~/.android` | recommended | Android、ADB 和模拟器配置与缓存数据 |
| Flutter/Dart Pub | `~/.pub-cache` | recommended | Dart 和 Flutter Pub 包缓存 |
| Bun | `~/.bun` | recommended | Bun JavaScript 运行时及缓存 |
| Conda | `~/.conda` | recommended | Anaconda/Miniconda 环境数据 |
| Composer | `~/.composer` | optional | PHP Composer 全局包 |
| Nexus | `~/.nexus` | optional | Nexus 代理缓存 |

## AI / 机器学习工具 <a href="#ai-机器学习工具" id="ai-机器学习工具"></a>

| 工具 | 路径 | 优先级 | 说明 |
|------|------|--------|------|
| Ollama | `~/.ollama` | recommended | 本地大语言模型存储 |
| PyTorch | `~/.cache/torch` | recommended | 预训练模型权重缓存 |
| Whisper | `~/.cache/whisper` | recommended | OpenAI 语音识别模型 |
| Keras | `~/.keras` | optional | Keras 模型和数据集 |
| NLTK | `~/nltk_data` | optional | 自然语言处理语料库 |

## AI 编程助手 <a href="#ai-编程助手" id="ai-编程助手"></a>

| 工具 | 路径 | 优先级 | 说明 |
|------|------|--------|------|
| 灵码（Lingma） | `~/.lingma` | optional | 阿里云 AI 编程助手 |
| Trae IDE | `~/.trae` | optional | 字节跳动 Trae IDE |
| Trae CN | `~/.trae-cn` | optional | Trae IDE 国内版 |
| Trae AICC | `~/.trae-aicc` | optional | Trae AICC |
| MarsCode | `~/.marscode` | optional | 字节跳动 MarsCode IDE |
| CodeBuddy | `~/.codebuddy` | optional | 腾讯 AI 助手 |
| CodeBuddy CN | `~/.codebuddycn` | optional | 腾讯 CodeBuddy 国内版 |
| Qwen | `~/.qwen` | optional | 阿里通义千问 |
| ClawBOT | `~/.clawdbot` | optional | ClawdBOT AI 工具 |

## 编辑器 / IDE <a href="#编辑器-ide" id="编辑器-ide"></a>

| 工具 | 路径 | 优先级 | 说明 |
|------|------|--------|------|
| VS Code | `~/.vscode` | optional | 扩展及配置 |
| Cursor | `~/.cursor` | optional | Cursor AI 编辑器 |
| Spring Tool Suite 4 | `~/.sts4` | optional | STS4 数据 |

## 浏览器 / 测试自动化 <a href="#浏览器-测试自动化" id="浏览器-测试自动化"></a>

| 工具 | 路径 | 优先级 | 说明 |
|------|------|--------|------|
| Selenium | `~/.cache/selenium` | optional | 自动下载的浏览器驱动 |
| Chromium | `~/.chromium-browser-snapshots` | optional | Playwright/Selenium 使用的浏览器快照 |
| WDM | `~/.wdm` | optional | WebDriver Manager 驱动程序 |

## 运行时环境 <a href="#运行时环境" id="运行时环境"></a>

| 工具 | 路径 | 优先级 | 说明 |
|------|------|--------|------|
| Docker | `~/.docker` | optional | Docker Desktop CLI 配置和上下文 |
| OpenClaw | `~/.openclaw` | optional | OpenClaw 工具数据 |

## 不可迁移的系统目录 <a href="#不可迁移的系统目录" id="不可迁移的系统目录"></a>

以下目录通常包含绝对路径引用或可执行文件，整体迁移可能导致工具失效，因此**不支持迁移**：

| 路径 | 原因 |
|------|------|
| `~/.local` | 包含可执行文件路径引用，迁移后命令行工具可能失效 |
| `~/.config` | 包含绝对路径配置，迁移后工具配置可能失效 |

## Conda 发行版特殊处理 <a href="#conda-发行版特殊处理" id="conda-发行版特殊处理"></a>

当应用的 Bundle ID 或名称包含 `anaconda`、`conda` 或 `miniconda` 时，AppPorts 会额外扫描以下路径，用于识别 Conda 安装根目录：

- `/opt/anaconda3`
- `/opt/miniconda3`
- `/usr/local/anaconda3`
- `/usr/local/miniconda3`
- `~/anaconda3`
- `~/miniconda3`
