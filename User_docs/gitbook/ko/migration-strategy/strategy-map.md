# 앱 유형 및 전략

| 앱 유형 | 컨테이너 분류 | 마이그레이션 전략 | 잠금 보호 | 비고 |
|---------|--------------|-----------------|----------|------|
| 네이티브 macOS 앱 (자체 업데이트 없음) | `standaloneApp` | macOS Stub Portal | 아니오 | 예: Safari, Finder |
| Sparkle 자체 업데이트 앱 | `standaloneApp` | macOS Stub Portal | **예** | 예: 일부 인디 개발자 앱 |
| Electron 앱 (`app-update.yml` 없음) | `standaloneApp` | macOS Stub Portal | 아니오 | 예: VS Code |
| Electron 앱 (`app-update.yml` 있음) | `standaloneApp` | macOS Stub Portal | **예** | 예: Slack, Discord |
| Electron + Sparkle 하이브리드 앱 | `standaloneApp` | macOS Stub Portal | **예** | 두 플래그가 독립적으로 감지됨 |
| 커스텀 업데이터 앱 (Chrome, Edge) | `standaloneApp` | macOS Stub Portal | 아니오 | `LaunchServices`, `KSProductID` 등으로 식별 |
| iOS 앱 (Mac 버전) | `standaloneApp` | iOS Stub Portal | 아니오 | 아이콘을 `WrappedBundle`에서 추출; 서명 없음 |
| Mac App Store 앱 | `standaloneApp` | macOS Stub Portal | 아니오 | SIP 보호; 재서명 불가 |
| 단일 앱 컨테이너 디렉토리 | `singleAppContainer` | Whole App Symlink | 아니오 | `.app` 1개만 있는 디렉토리; 전체 symlink |
| 앱 스위트 디렉토리 (예: Office) | `appSuiteFolder` | Whole App Symlink | 내부 앱에 따라 다름 | `.app` 2개 이상이 있는 디렉토리; 전체 symlink |
| `.app`이 아닌 경로 | — | Whole App Symlink | — | `.app`이 아닌 확장자를 가진 경로 |

{% hint style="warning" %}
**⚠️ 잠금 보호에 관하여**

앱이 잠금이 필요한 것으로 표시되면(`needsLock = true`), AppPorts는 마이그레이션 완료 후 외장 저장소 앱에 `chflags -R uchg`를 실행하여 불변 플래그를 설정합니다. 이는 자체 업데이트 프로그램이 외부 복사본을 삭제하거나 수정하는 것을 방지하지만, 앱이 자체 업데이트를 할 수 없게 됩니다. 사용자는 업데이트 전에 AppPorts에서 수동으로 잠금을 해제해야 합니다.
{% endhint %}

{% hint style="success" %}
**💡 커스텀 업데이터 앱이 잠기지 않는 이유**

Chrome이나 Edge와 같은 커스텀 업데이터를 사용하는 앱은 잠기지 않습니다. 이러한 앱의 업데이터는 일반적으로 새 버전을 로컬 내부 저장소에 다운로드하여 설치합니다. macOS Stub Portal의 링크 격리 특성으로 인해 외장 저장소의 앱 파일이 손상되지 않습니다.

AppPorts가 로컬 내부 저장소의 앱 버전이 외장 저장소의 버전보다 높은 것을 감지하면, 자동으로 앱에 "이동 대기" 태그를 지정하여 사용자에게 최신 버전을 동기화하도록 재마이그레이션을 안내합니다.
{% endhint %}
