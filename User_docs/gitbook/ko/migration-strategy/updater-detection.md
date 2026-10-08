# 자체 업데이트 감지

## Electron 앱 감지 <a href="#electron-앱-감지" id="electron-앱-감지"></a>

AppPorts는 다음 세 가지 감지 조건을 통해 Electron 앱을 식별합니다 (우선순위 순서로 확인, 단락 평가):

| # | 감지 항목 | 경로 / 패턴 |
|---|----------|------------|
| 1 | Electron 프레임워크 | `Contents/Frameworks/Electron Framework.framework` 디렉토리 존재 |
| 2 | Electron Helper 변형 | `Contents/Frameworks/` 아래에 `Electron Helper`를 이름에 포함하는 엔트리 존재 |
| 3 | Info.plist 식별 키 | `Contents/Info.plist`에 `ElectronDefaultApp` 또는 `electron` 키 존재 |

### Electron 자체 업데이트 감지 <a href="#electron-자체-업데이트-감지" id="electron-자체-업데이트-감지"></a>

추가로 `Contents/Resources/app-update.yml` 파일의 존재 여부를 확인합니다 (`electron-updater`의 설정 파일). 존재하면 해당 Electron 앱은 자체 업데이트 기능을 가진 것으로 표시됩니다.

## Sparkle 앱 감지 <a href="#sparkle-앱-감지" id="sparkle-앱-감지"></a>

AppPorts는 다음 세 가지 감지 조건을 통해 Sparkle 앱을 식별합니다:

| # | 감지 항목 | 경로 / 패턴 |
|---|----------|------------|
| 1 | Sparkle 프레임워크 | `Contents/Frameworks/Sparkle.framework` 또는 `Contents/Frameworks/Squirrel.framework` 존재 |
| 2 | 업데이트 바이너리 파일 | `Contents/MacOS/` 또는 `Contents/Frameworks/` 아래에 `shipit`, `autoupdate`, `updater`, `update`와 일치하는 파일 존재 |
| 3 | Info.plist Sparkle 키 | `Contents/Info.plist`에 다음 키 중 하나라도 존재: `SUFeedURL`, `SUPublicDSAKeyFile`, `SUPublicEDKey`, `SUScheduledCheckInterval`, `SUAllowsAutomaticUpdates` |

{% hint style="warning" %}
**⚠️ Electron 앱에 대한 특별 처리**

앱이 Electron 앱으로 식별된 경우, 감지 조건 #2 (업데이트 바이너리 파일)가 건너뛰어져 `electron-updater`의 `updater` 바이너리가 Sparkle로 잘못 감지되는 것을 방지합니다.
{% endhint %}

## 하이브리드 Electron + Sparkle 앱 <a href="#하이브리드-electron-sparkle-앱" id="하이브리드-electron-sparkle-앱"></a>

일부 앱은 Electron 프레임워크와 Sparkle 업데이트 프로그램을 모두 포함합니다. AppPorts는 두 플래그를 독립적으로 감지하여 `isElectron`과 `isSparkle`이 모두 `true`가 될 수 있습니다.

### 감지 로직 <a href="#감지-로직" id="감지-로직"></a>

```text
isElectron = 세 가지 Electron 감지 조건 중 하나라도 만족
isSparkle  = 세 가지 Sparkle 감지 조건 중 하나라도 만족 (Electron 앱은 조건 #2 건너뜀)
```

두 플래그는 독립적이며 동시에 모두 true가 될 수 있습니다.

### 마이그레이션 후 동작 <a href="#마이그레이션-후-동작" id="마이그레이션-후-동작"></a>

| 속성 | 결정 조건 |
|------|----------|
| `hasSelfUpdater` | `isSparkle` 또는 (`isElectron` 및 `app-update.yml` 존재) 또는 커스텀 업데이트 프로그램 존재 |
| `needsLock` | `isSparkle` 또는 (`isElectron` 및 `app-update.yml` 존재) |

`needsLock`이 `true`이면, AppPorts는 마이그레이션 완료 후 외장 저장소 앱에 `chflags -R uchg` (불변 플래그 설정)를 실행하여 자체 업데이트 프로그램이 외부 복사본을 삭제하거나 수정하는 것을 방지합니다.

## 커스텀 업데이트 감지 <a href="#커스텀-업데이트-감지" id="커스텀-업데이트-감지"></a>

Sparkle이나 Electron이 아닌 네이티브 자체 업데이트 앱(예: Chrome, Edge, Parallels)의 경우, AppPorts는 다음 패턴을 통해 식별합니다:

| 감지 경로 | 매칭 패턴 | 대표 앱 |
|-----------|----------|---------|
| `Contents/Library/LaunchServices/` | 파일 이름에 `update` 포함 | Chrome, Edge, Thunderbird |
| `Contents/MacOS/` | 바이너리 파일 이름에 `update` 또는 `upgrade` 포함 (`electron` 제외) | Parallels, Thunderbird |
| `Contents/SharedSupport/` | 파일 이름에 `update` 포함 | WPS Office |
| `Contents/Info.plist` | `KSProductID` 키 존재 | Google Keystone (Chrome) |

## 레거시 전략 식별 <a href="#레거시-전략-식별" id="레거시-전략-식별"></a>

복원 또는 링크 해제 시, AppPorts는 이전 버전으로 생성된 레거시 엔트리를 식별해야 합니다:

| 로컬 구조 특성 | 식별 결과 |
|----------------|----------|
| 루트 경로가 심볼릭 링크 | `wholeAppSymlink` |
| `Contents/`가 심볼릭 링크 | `deepContentsWrapper` |
| `Contents/Info.plist`가 심볼릭 링크 | `wholeAppSymlink` (레거시 Sparkle 하이브리드 방식) |
| `Contents/Frameworks/`가 심볼릭 링크 | `wholeAppSymlink` (레거시 Electron 하이브리드 방식) |
| `Contents/MacOS/launcher` 존재 | `stubPortal` |
| 위에 해당하지 않음 | AppPorts가 관리하지 않음 |
