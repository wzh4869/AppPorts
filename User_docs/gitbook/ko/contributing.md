---
icon: "code-pull-request"
layout:
  width: "default"
  outline:
    visible: true
---

# 기여하기

AppPorts에 관심을 가져주셔서 감사합니다! 커뮤니티 구성원의 기여를 환영합니다. 버그 수정, 문서 개선, 새 기능 추가 모두 가능합니다.

## 시작하기 전에 <a href="#시작하기-전에" id="시작하기-전에"></a>

1. 기존 [Issues](https://github.com/wzh4869/AppPorts/issues)를 검색하여 관련 중복이 없는지 확인
2. 프로젝트를 Fork하고 로컬에 클론
3. `develop` 브랜치를 기반으로 기능 브랜치(`feat/your-feature`) 또는 수정 브랜치(`feat/your-fix`) 생성

## 개발 방식 <a href="#개발-방식" id="개발-방식"></a>

### Vibe Coding에 관하여 <a href="#vibe-coding에-관하여" id="vibe-coding에-관하여"></a>

AppPorts 프로젝트는 AI 지원 도구(예: Cursor, GitHub Copilot, Claude)를 사용한 Vibe Coding 개발을 허용합니다. AI 도구가 개발 효율을 크게 향상시킬 수 있다는 것을 이해하지만, **제출된 코드의 품질과 정확성은 기여자의 책임입니다**.

Vibe Coding 사용 시:

- **AI 어시스턴트는 프로젝트 루트의 `CLAUDE.md`를 따라야 합니다**, 여기에는 코딩 가이드라인, 아키텍처 규칙, 빌드 명령 및 개발 워크플로가 정의되어 있습니다. AI 어시스턴트가 이 파일을 자동으로 읽지 않으면, 프롬프트에서 명시적으로 `CLAUDE.md`를 먼저 읽도록 요청하세요
- 단일 모델의 사각지대를 피하기 위해 여러 AI 모델로 생성된 코드의 품질과 보안을 교차 검증하는 것을 고려하세요
- AI가 생성한 코드는 프로젝트의 기존 스타일과 일치하지 않을 수 있으므로; 제출 전에 수동으로 검토하세요
- AI는 macOS 시스템 동작에 대한 이해를 대체할 수 없습니다; 파일 시스템 작업, 코드 서명 및 권한 관리와 관련된 로직은 수동으로 검증하세요
- **핵심 기능** 변경 (예: 마이그레이션 전략, 데이터 디렉토리 마이그레이션, 코드 서명)은 개발 전에 Issue를 통해 먼저 논의해야 합니다

### 코드 규칙 <a href="#코드-규칙" id="코드-규칙"></a>

- Swift 코드 규칙 및 프로젝트의 기존 스타일을 따르세요
- 복잡한 로직에 대해 명확한 Swift 문서 주석을 작성하세요
- SwiftUI 문자열 리터럴은 `LocalizedStringKey` API를 사용; AppKit/API 문자열은 `.localized`를 사용

## 테스트 요구 사항 <a href="#테스트-요구-사항" id="테스트-요구-사항"></a>

{% hint style="warning" %}
**⚠️ 모든 PR은 테스트를 통과해야 합니다**

개발 방법과 관계없이, PR을 제출하기 전에 다음 테스트를 완료해야 합니다. CI는 자동으로 컴파일 스모크 체크를 실행하며; 통과하지 못한 PR은 병합이 차단됩니다.
{% endhint %}

### 필수: 컴파일 스모크 체크 <a href="#필수-컴파일-스모크-체크" id="필수-컴파일-스모크-체크"></a>

모든 PR은 Xcode Release 컴파일을 통과해야 합니다 — 이는 병합을 위한 필수 요구 사항입니다:

```bash
xcodebuild clean build \
  -scheme "AppPorts" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -CODE_SIGN_IDENTITY="" \
  -CODE_SIGNING_REQUIRED=NO \
  -CODE_SIGN_ENTITLEMENTS="" \
  -CODE_SIGNING_ALLOWED=NO
```

### 선택: 전문 테스트 <a href="#선택-전문-테스트" id="선택-전문-테스트"></a>

PR이 해당 모듈을 포함하는 경우, 다음 전문 테스트를 실행하는 것을 권장합니다. CI도 PR에서 Advisory 모드로 실행합니다; 결과가 병합을 차단하지 않지만 피드백을 제공합니다.

#### 데이터 디렉토리 테스트 <a href="#데이터-디렉토리-테스트" id="데이터-디렉토리-테스트"></a>

PR이 `DataDirMover`, `DataDirScanner` 또는 데이터 디렉토리 마이그레이션 로직을 포함할 때 실행:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/DataDirMoverTests" \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  -CODE_SIGN_IDENTITY="" \
  -CODE_SIGNING_REQUIRED=NO \
  -CODE_SIGN_ENTITLEMENTS="" \
  -CODE_SIGNING_ALLOWED=NO
```

#### 앱 마이그레이션 테스트 <a href="#앱-마이그레이션-테스트" id="앱-마이그레이션-테스트"></a>

PR이 `AppMigrationService`, `AppScanner` 또는 앱 마이그레이션 로직을 포함할 때 실행:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppMigrationServiceTests" \
  -only-testing:"AppPortsTests/AppScannerTests" \
  -CODE_SIGN_IDENTITY="" \
  -CODE_SIGNING_REQUIRED=NO \
  -CODE_SIGN_ENTITLEMENTS="" \
  -CODE_SIGNING_ALLOWED=NO
```

#### 로깅 테스트 <a href="#로깅-테스트" id="로깅-테스트"></a>

PR이 `AppLogger` 또는 진단 기능을 포함할 때 실행:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppLoggerTests" \
  -CODE_SIGN_IDENTITY="" \
  -CODE_SIGNING_REQUIRED=NO \
  -CODE_SIGN_ENTITLEMENTS="" \
  -CODE_SIGNING_ALLOWED=NO
```

#### 현지화 감사 <a href="#현지화-감사" id="현지화-감사"></a>

PR이 사용자에게 보이는 텍스트, 메뉴, 팝업, 설정 또는 오류 메시지를 포함할 때 실행:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  -CODE_SIGN_IDENTITY="" \
  -CODE_SIGNING_REQUIRED=NO \
  -CODE_SIGN_ENTITLEMENTS="" \
  -CODE_SIGNING_ALLOWED=NO
```

### 테스트 개요 <a href="#테스트-개요" id="테스트-개요"></a>

| 테스트 스위트 | 모듈 | 실행 시기 |
|--------------|------|----------|
| 컴파일 스모크 체크 | 전체 프로젝트 | **필수** (CI 강제) |
| `DataDirMoverTests` | 데이터 디렉토리 마이그레이션 | `DataDirMover` 관련 시 |
| `DataDirScannerTests` | 데이터 디렉토리 스캔 | `DataDirScanner` 관련 시 |
| `AppMigrationServiceTests` | 앱 마이그레이션 | `AppMigrationService` 관련 시 |
| `AppScannerTests` | 앱 스캔 | `AppScanner` 관련 시 |
| `AppLoggerTests` | 로깅 및 진단 | `AppLogger` 관련 시 |
| `LocalizationAuditTests` | 현지화 | 사용자에게 보이는 텍스트 관련 시 |

## 현지화 <a href="#현지화" id="현지화"></a>

- 현지화 적응은 권장하지만 외부 기여자 PR에 필수는 아닙니다
- PR이 사용자에게 보이는 텍스트를 추가, 수정 또는 삭제하는 경우, 동일 PR에서 `Localizable.xcstrings`를 업데이트해 주세요
- 이번에 처리하지 않을 경우, PR 설명에 이유나 향후 계획을 간략히 설명해 주세요
- SwiftUI 문자열 리터럴은 `LocalizedStringKey` API를 사용; AppKit/API 문자열은 `.localized`를 사용
- 동적 텍스트는 형식화된 키를 사용해야 합니다, 예: `String(format: "Sort: %@".localized, value)`
- 언어 목록은 `AppLanguageCatalog`에서 관리; 여러 페이지에서 중복하지 마세요
- PR이 메뉴, 팝업, 설정, 로그 내보내기, 오류 메시지, 상태 텍스트 또는 온보딩 텍스트를 변경하는 경우, 최소한 `zh-Hans`와 `en` 표시 결과를 확인하는 것을 권장합니다

더 많은 규칙은: [LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)를 참조하세요

## 커밋 규칙 <a href="#커밋-규칙" id="커밋-규칙"></a>

- **Issue 우선**: 중요한 기능 변경은 먼저 Issue를 통해 논의해야 합니다
- **원자성 유지**: 각 PR은 이상적으로 하나의 문제만 해결하거나 하나의 기능만 추가해야 합니다
- **커밋 메시지 제안**:
  - `feat: ...` — 새 기능
  - `fix: ...` — 버그 수정
  - `docs: ...` — 문서 업데이트
  - `refactor: ...` — 리팩토링
  - `test: ...` — 테스트 관련

## PR 제출 <a href="#pr-제출" id="pr-제출"></a>

1. 브랜치가 최신 `develop` 브랜치를 기반으로 하는지 확인
2. Fork 저장소에 Push
3. AppPorts의 `develop` 브랜치로 Pull Request 제출
4. PR 템플릿의 필수 항목을 작성
5. CI 검사 통과 및 코드 리뷰 대기

{% hint style="success" %}
**💡 병합 효율 향상**

- 각 PR을 하나의 문제 또는 기능에 집중시키세요
- PR 템플릿에 테스트 상황을 솔직하게 작성하세요
- UI 변경 시 스크린샷을 포함하세요
{% endhint %}

## 환영하는 기여 분야 <a href="#환영하는-기여-분야" id="환영하는-기여-분야"></a>

- `AppScanner` 같은 핵심 로직의 안정성 및 성능 개선
- UI/UX 최적화, 특히 macOS에 네이티브하게 느껴지는 개선
- 중국어 및 영문 문서의 동기화 및 개선
