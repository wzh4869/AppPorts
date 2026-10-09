---
icon: "compass"
layout:
  width: "default"
  outline:
    visible: true
---

# AppPorts 사용자 가이드

이 가이드는 AppPorts의 핵심 기능, 설계 원칙과 기술 구현을 설명합니다. 자세한 기술 정보는 [DeepWiki](https://deepwiki.com/wzh4869/AppPorts)를 참조하세요. 개선 의견은 프로젝트 [Issues](https://github.com/wzh4869/AppPorts/issues)에 남겨 주세요.

## 개요 <a href="#개요" id="개요"></a>

AppPorts는 [macOS](https://www.apple.com.cn/os/macos/)용 앱 마이그레이션 및 연결 도구입니다. 대용량 앱을 외장 저장 장치로 옮기면서 Finder, Launchpad, 앱 메뉴와 시스템 업데이트의 동작을 가능한 한 일관되게 유지합니다.

### AppPorts의 철학 <a href="#appports의-철학" id="appports의-철학"></a>

| 원칙 | 설명 |
|------|------|
| **익숙한 사용 경험** | 사용자와 운영 체제가 마이그레이션한 앱을 로컬 앱처럼 사용할 수 있도록 함 |
| **안정적인 전략** | 검증을 거쳐 마이그레이션 안정성이 높은 방식을 우선함 |
| **낮은 시스템 부하** | 데몬에 의존하지 않아 시스템 리소스를 계속 점유하지 않음 |
| **폭넓은 국제화** | 더 많은 언어를 지원하면서 번역 품질을 지속적으로 개선함 |
| **손쉬운 사용 지원** | 폭넓은 손쉬운 사용 기능을 제공함 |

## 핵심 기능 <a href="#핵심-기능" id="핵심-기능"></a>

- **바로가기 화살표 없는 마이그레이션**: 클릭 한 번으로 대용량 앱을 외장 저장 장치로 옮깁니다. 로컬에는 가벼운 실행 셸만 남기며 Finder에 바로가기 화살표가 표시되지 않습니다. Launchpad와 macOS 앱 메뉴에도 정상적으로 표시됩니다.
- **자동 업데이트 보호**: Sparkle, Electron, Chrome 등 자체 업데이트 기능이 있는 앱을 자동으로 감지합니다. “잠금 마이그레이션”을 선택하면 업데이터가 외장 저장 장치의 앱을 삭제하거나 덮어쓰는 것을 막을 수 있습니다.
- **버전 동기화 안내**: 로컬의 실제 앱이 외장 저장 장치의 이전 사본보다 최신 버전이면 “내보내기 대기”로 표시합니다. 로컬의 새 버전을 마이그레이션하여 외장 저장 장치의 이전 버전을 교체할 수 있습니다.
- **Stub Portal 버전 동기화**: 외장 드라이브의 앱이 App Store에서 업데이트되면 로컬 Stub Portal의 버전 정보도 자동으로 동기화되어 “다음으로 열기” 메뉴에 올바른 버전이 표시됩니다.
- **사용자 지정 스캔 디렉토리**: JetBrains Toolbox, Steam 등의 로컬 앱 디렉토리를 추가할 수 있습니다. 추가한 디렉토리는 자동으로 저장되며 변경 사항을 감시합니다.
- **코드 서명 관리**: 앱 본체를 마이그레이션한 뒤 손상되었다는 메시지가 표시되면 오른쪽 클릭 메뉴에서 재서명할 수 있습니다. 원본 서명의 백업과 복원을 지원합니다. 샌드박스 앱은 어떤 경우에도 재서명하지 않습니다.
- **macOS 15.1+ App Store 지원**: App Store 앱을 외장 저장 장치에 직접 설치하고, Mac으로 되돌리지 않고도 그 위치에서 업데이트할 수 있습니다.
- **클릭 한 번으로 복원**: 앱을 로컬로 되돌리면서 링크를 자동으로 제거합니다. 마이그레이션이 중단되면 자동 복구할 수 있습니다.
- **데이터 디렉토리 관리**: `~/Library/` 하위 디렉토리, `~/.npm` 등의 앱 데이터 디렉토리를 외장 저장 장치로 마이그레이션합니다. 트리 형태의 그룹 보기, 검색과 정렬을 지원하며 AppPorts 메타데이터로 복원 대상을 엄격히 검증합니다.
- **컨테이너 데이터 마운트 마이그레이션**: WeChat 채팅 기록과 같은 샌드박스 컨테이너 데이터는 외장 APFS 드라이브에 별도 볼륨을 만들고 원래 디렉토리에 마운트하여 옮깁니다. 앱 서명은 변경하지 않습니다.
- **디렉토리 마이그레이션**: 사용자 홈 디렉토리의 실제 폴더를 외장 저장 장치로 마이그레이션할 수 있습니다. 대형 프로젝트, 모델, 미디어 라이브러리와 도구 캐시에 적합하며 다시 연결, 복원과 경로 중복 검사를 지원합니다.

## 마이그레이션 전략 <a href="#마이그레이션-전략" id="마이그레이션-전략"></a>

### Deep Contents Wrapper (Contents 디렉토리 마이그레이션) <a href="#deep-contents-wrapper-contents-디렉토리-마이그레이션" id="deep-contents-wrapper-contents-디렉토리-마이그레이션"></a>

macOS 앱의 일반적인 파일 구조는 다음과 같습니다.

```text
/Applications/Safari.app/
├── Contents/
│   ├── MacOS/
│   ├── Resources/
│   ├── Frameworks/
│   └── Info.plist
└── ...
```

Deep Contents Wrapper는 앱의 모든 내용을 외장 저장 장치로 옮기고, 로컬에 같은 이름의 빈 `.app` 디렉토리를 만듭니다. 이 디렉토리에는 외장 저장 장치의 `Contents` 디렉토리를 가리키는 심볼릭 링크만 들어 있습니다. macOS가 이를 완전한 `.app` 번들로 인식하므로 Finder에 바로가기 화살표가 표시되지 않으며 아이콘, Launchpad와 앱 메뉴가 정상적으로 작동합니다.

{% hint style="warning" %}
**현재 버전에서는 이 전략을 더 이상 사용하지 않습니다**

Deep Contents Wrapper의 주요 단점은 자동 업데이터가 심볼릭 링크를 따라 외장 저장 장치의 파일을 직접 변경하여 앱 본체를 손상시킬 수 있다는 점입니다.
{% endhint %}

### Stub Portal (실행 셸 방식) <a href="#stub-portal-실행-셸-방식" id="stub-portal-실행-셸-방식"></a>

Stub Portal은 다음 네 가지 구성 요소만 포함하는 최소한의 `.app` 셸을 로컬에 만듭니다.

| 구성 요소 | 설명 |
|------|------|
| `Contents/MacOS/launcher` | `open "/Volumes/External/SomeApp.app"`을 실행하는 런처 |
| `Contents/Resources/` | 외장 저장 장치의 앱에서 복사한 아이콘 파일 |
| `Contents/Info.plist` | 외부 앱의 `Info.plist`를 바탕으로 간소화하여 생성. `CFBundleExecutable`을 `launcher`로 설정하고, Dock에 표시되지 않도록 `LSUIElement=true`를 추가하며 업데이트 관련 설정 키를 모두 제거 |
| `Contents/PkgInfo` | 표준 4바이트 식별 파일 |

사용자가 이 셸을 클릭하면 macOS가 `launcher`를 실행하고, `open` 명령으로 외장 저장 장치의 실제 앱을 시작합니다. 로컬에 심볼릭 링크가 없으므로 자동 업데이터가 링크를 따라 외부 앱에 접근할 수 없습니다.

### iOS Stub Portal (iOS 실행 셸 방식) <a href="#ios-stub-portal-ios-실행-셸-방식" id="ios-stub-portal-ios-실행-셸-방식"></a>

기본 원리는 일반 Stub Portal과 같지만 아이콘 처리 방식이 다릅니다. iOS 앱의 아이콘은 `Info.plist`에 지정되어 있지 않고, `Wrapper/` 또는 `WrappedBundle/` 디렉토리에 여러 `AppIcon.png` 파일로 저장됩니다. 처리 과정은 다음과 같습니다.

1. 해상도가 가장 높은 `AppIcon.png` 파일을 찾습니다.
2. `sips`로 256×256픽셀 크기로 조정합니다.
3. `sips`로 `.icns` 형식으로 변환합니다.
4. iOS 앱에는 표준 `Info.plist`가 없으므로 `iTunesMetadata.plist`를 바탕으로 `Info.plist`를 생성합니다.

### Whole Symlink (전체 심볼릭 링크) <a href="#whole-symlink-전체-심볼릭-링크" id="whole-symlink-전체-심볼릭-링크"></a>

전체 `.app` 디렉토리를 외장 저장 장치를 가리키는 심볼릭 링크로 만듭니다.

```text
/Applications/SomeApp.app → /Volumes/External/SomeApp.app
```

로컬에는 실제 앱 파일 없이 심볼릭 링크만 남습니다. macOS는 대체로 앱을 정상적으로 열 수 있지만, Finder는 아이콘에 바로가기 화살표를 표시하고 Launchpad에서는 호환성 문제가 발생할 수 있습니다. 자동 업데이터 역시 심볼릭 링크를 따라 외부 앱 파일을 변경할 수 있습니다. 따라서 AppPorts는 이 방식을 주로 다른 방식을 사용할 수 없을 때의 대안으로 사용합니다.
