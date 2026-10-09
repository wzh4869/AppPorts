---
icon: "terminal"
description: "감지할 수 있는 도구 데이터 디렉토리를 확인합니다."
layout:
  width: "default"
  outline:
    visible: true
---

# 도구 디렉토리 감지

![](https://pic.cdn.shimoko.com/tools.png)

AppPorts는 사용자의 홈 디렉토리에 있는 일반적인 개발 도구, AI 도구, 편집기가 생성한 데이터 디렉토리(dot-folder)를 자동으로 감지하고 외장 저장소로 마이그레이션을 지원합니다. 더 많은 도구 마이그레이션 요구 사항은 프로젝트 [Issues](https://github.com/wzh4869/AppPorts/issues)에 제출해 주세요.

## 우선순위 수준 <a href="#우선순위-수준" id="우선순위-수준"></a>

| 우선순위 | 의미 |
|----------|------|
| `critical` | 마이그레이션 후 반드시 동작해야 함; 핵심 애플리케이션 기능에 영향 |
| `recommended` | 큰 공간 절약; 마이그레이션 효용이 높음 |
| `optional` | 크기가 작거나 재구성 가능 |

## 개발 도구 / 패키지 관리자 <a href="#개발-도구-패키지-관리자" id="개발-도구-패키지-관리자"></a>

| 도구 | 경로 | 우선순위 | 설명 |
|------|------|----------|------|
| npm | `~/.npm` | recommended | Node.js 패키지 관리자 로컬 캐시 |
| Maven | `~/.m2` | recommended | Java Maven 의존성 저장소 |
| Gradle | `~/.gradle` | recommended | Gradle 빌드 캐시, Wrapper 및 의존성 데이터 |
| Android 개발 데이터 | `~/.android` | recommended | Android, ADB 및 에뮬레이터 설정과 캐시 데이터 |
| Flutter/Dart Pub | `~/.pub-cache` | recommended | Dart 및 Flutter Pub 패키지 캐시 |
| Bun | `~/.bun` | recommended | Bun JavaScript 런타임 및 캐시 |
| Conda | `~/.conda` | recommended | Anaconda/Miniconda 환경 데이터 |
| Composer | `~/.composer` | optional | PHP Composer 글로벌 패키지 |
| Nexus | `~/.nexus` | optional | Nexus 프록시 캐시 |

## AI / 머신러닝 도구 <a href="#ai-머신러닝-도구" id="ai-머신러닝-도구"></a>

| 도구 | 경로 | 우선순위 | 설명 |
|------|------|----------|------|
| Ollama | `~/.ollama` | recommended | 로컬 대규모 언어 모델 저장소 |
| PyTorch | `~/.cache/torch` | recommended | 사전 학습된 모델 가중치 캐시 |
| Whisper | `~/.cache/whisper` | recommended | OpenAI 음성 인식 모델 |
| Keras | `~/.keras` | optional | Keras 모델 및 데이터셋 |
| NLTK | `~/nltk_data` | optional | 자연어 처리 코퍼스 |

## AI 코딩 어시스턴트 <a href="#ai-코딩-어시스턴트" id="ai-코딩-어시스턴트"></a>

| 도구 | 경로 | 우선순위 | 설명 |
|------|------|----------|------|
| Lingma | `~/.lingma` | optional | Alibaba Cloud AI 코딩 어시스턴트 |
| Trae IDE | `~/.trae` | optional | ByteDance Trae IDE |
| Trae CN | `~/.trae-cn` | optional | Trae IDE 국내 버전 |
| Trae AICC | `~/.trae-aicc` | optional | Trae AICC |
| MarsCode | `~/.marscode` | optional | ByteDance MarsCode IDE |
| CodeBuddy | `~/.codebuddy` | optional | Tencent AI 어시스턴트 |
| CodeBuddy CN | `~/.codebuddycn` | optional | Tencent CodeBuddy 국내 버전 |
| Qwen | `~/.qwen` | optional | Alibaba 통의천문 |
| ClawBOT | `~/.clawdbot` | optional | ClawdBOT AI 도구 |

## 편집기 / IDE <a href="#편집기-ide" id="편집기-ide"></a>

| 도구 | 경로 | 우선순위 | 설명 |
|------|------|----------|------|
| VS Code | `~/.vscode` | optional | 확장 프로그램 및 설정 |
| Cursor | `~/.cursor` | optional | Cursor AI 편집기 |
| Spring Tool Suite 4 | `~/.sts4` | optional | STS4 데이터 |

## 브라우저 / 테스트 자동화 <a href="#브라우저-테스트-자동화" id="브라우저-테스트-자동화"></a>

| 도구 | 경로 | 우선순위 | 설명 |
|------|------|----------|------|
| Selenium | `~/.cache/selenium` | optional | 자동 다운로드된 브라우저 드라이버 |
| Chromium | `~/.chromium-browser-snapshots` | optional | Playwright/Selenium이 사용하는 브라우저 스냅샷 |
| WDM | `~/.wdm` | optional | WebDriver Manager 드라이버 프로그램 |

## 런타임 환경 <a href="#런타임-환경" id="런타임-환경"></a>

| 도구 | 경로 | 우선순위 | 설명 |
|------|------|----------|------|
| Docker | `~/.docker` | optional | Docker Desktop CLI 설정 및 컨텍스트 |
| OpenClaw | `~/.openclaw` | optional | OpenClaw 도구 데이터 |

## 마이그레이션 불가능한 시스템 디렉토리 <a href="#마이그레이션-불가능한-시스템-디렉토리" id="마이그레이션-불가능한-시스템-디렉토리"></a>

다음 디렉토리는 절대 경로 참조 또는 실행 파일을 포함하고 있어 마이그레이션하면 도구가 실패할 수 있습니다. **마이그레이션이 지원되지 않습니다**:

| 경로 | 이유 |
|------|------|
| `~/.local` | 실행 경로 참조를 포함; 마이그레이션 후 커맨드라인 도구가 실패할 수 있음 |
| `~/.config` | 절대 경로 설정을 포함; 마이그레이션 후 도구 설정이 실패할 수 있음 |

## Conda 배포 특별 처리 <a href="#conda-배포-특별-처리" id="conda-배포-특별-처리"></a>

앱의 Bundle ID 또는 이름에 `anaconda`, `conda`, 또는 `miniconda`가 포함된 경우, AppPorts는 Conda 설치 루트를 식별하기 위해 다음 경로를 추가로 스캔합니다:

- `/opt/anaconda3`
- `/opt/miniconda3`
- `/usr/local/anaconda3`
- `/usr/local/miniconda3`
- `~/anaconda3`
- `~/miniconda3`
