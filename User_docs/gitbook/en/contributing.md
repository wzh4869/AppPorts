---
icon: "code-pull-request"
layout:
  width: "default"
  outline:
    visible: true
---

# Contributing

Thank you for your interest in AppPorts! We welcome community members to contribute, whether it's fixing bugs, improving documentation, or adding new features.

## Before You Start <a href="#before-you-start" id="before-you-start"></a>

1. Search existing [Issues](https://github.com/wzh4869/AppPorts/issues) to confirm no related duplicates
2. Fork the project and clone locally
3. Create a feature branch (`feat/your-feature`) or fix branch (`fix/your-fix`) based on the `develop` branch

## Development Approach <a href="#development-approach" id="development-approach"></a>

### About Vibe Coding <a href="#about-vibe-coding" id="about-vibe-coding"></a>

The AppPorts project accepts Vibe Coding development using AI-assisted tools (e.g., Cursor, GitHub Copilot, Claude). We understand AI tools can significantly improve development efficiency, **but the quality and correctness of submitted code is the contributor's responsibility**.

When using Vibe Coding:

- **AI assistants must follow the project root's `CLAUDE.md`**, which defines coding guidelines, architecture conventions, build commands, and development workflow. If the AI assistant doesn't automatically read this file, explicitly ask it to read `CLAUDE.md` first in your prompts
- Consider cross-validating generated code quality and security with multiple AI models to avoid blind spots of a single model
- AI-generated code may not match the project's existing style; please review manually before submission
- AI cannot replace understanding of macOS system behavior; please manually verify logic involving file system operations, code signing, and permission management
- **Core functionality** changes (e.g., migration strategies, data directory migration, code signing) must first be discussed via Issue before development

### Code Conventions <a href="#code-conventions" id="code-conventions"></a>

- Follow Swift code conventions and the project's existing style
- Write clear Swift documentation comments for complex logic
- SwiftUI string literals use `LocalizedStringKey` API; AppKit/API strings use `.localized`

## Testing Requirements <a href="#testing-requirements" id="testing-requirements"></a>

{% hint style="warning" %}
**⚠️ All PRs Must Pass Tests**

Regardless of development method, the following tests must be completed before submitting a PR. CI automatically runs compile smoke checks; unpassed PRs will be blocked from merging.
{% endhint %}

### Required: Compile Smoke Check <a href="#required-compile-smoke-check" id="required-compile-smoke-check"></a>

All PRs must pass Xcode Release compilation — this is a hard requirement for merging:

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

### On-Demand: Specialized Tests <a href="#on-demand-specialized-tests" id="on-demand-specialized-tests"></a>

When a PR involves corresponding modules, it is recommended to proactively run the following specialized tests. CI also runs these in Advisory mode in PRs; results do not block merging but provide feedback.

#### Data Directory Tests <a href="#data-directory-tests" id="data-directory-tests"></a>

Run when PR involves `DataDirMover`, `DataDirScanner`, or data directory migration logic:

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

#### App Migration Tests <a href="#app-migration-tests" id="app-migration-tests"></a>

Run when PR involves `AppMigrationService`, `AppScanner`, or app migration logic:

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

#### Logging Tests <a href="#logging-tests" id="logging-tests"></a>

Run when PR involves `AppLogger` or diagnostic functionality:

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

#### Localization Audit <a href="#localization-audit" id="localization-audit"></a>

Run when PR involves user-visible text, menus, popups, settings, or error messages:

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

### Test Overview <a href="#test-overview" id="test-overview"></a>

| Test Suite | Modules | When to Run |
|------------|---------|-------------|
| Compile Smoke Check | Entire project | **Required** (CI enforced) |
| `DataDirMoverTests` | Data directory migration | When involving `DataDirMover` |
| `DataDirScannerTests` | Data directory scanning | When involving `DataDirScanner` |
| `AppMigrationServiceTests` | App migration | When involving `AppMigrationService` |
| `AppScannerTests` | App scanning | When involving `AppScanner` |
| `AppLoggerTests` | Logging & diagnostics | When involving `AppLogger` |
| `LocalizationAuditTests` | Localization | When involving user-visible text |

## Localization <a href="#localization" id="localization"></a>

- Localization adaptation is recommended but not mandatory for external contributor PRs
- If a PR adds, modifies, or deletes user-visible text, you're welcome to update `Localizable.xcstrings` in the same PR
- If not handling it this time, please briefly explain the reason or future plan in the PR description
- SwiftUI string literals use `LocalizedStringKey` API; AppKit/API strings use `.localized`
- Dynamic text should use formatted keys, e.g., `String(format: "Sort: %@".localized, value)`
- Language list is maintained in `AppLanguageCatalog`; do not duplicate in multiple pages
- If a PR changes menus, popups, settings, log exports, error messages, status text, or onboarding text, it is recommended to check at least the `zh-Hans` and `en` display results

More rules see: [LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Commit Conventions <a href="#commit-conventions" id="commit-conventions"></a>

- **Issue First**: Important feature changes should first be discussed via Issue
- **Keep Atomic**: Each PR should ideally address only one issue or add one feature
- **Commit Message Suggestions**:
  - `feat: ...` — New feature
  - `fix: ...` — Bug fix
  - `docs: ...` — Documentation update
  - `refactor: ...` — Refactoring
  - `test: ...` — Test related

## Submitting a PR <a href="#submitting-a-pr" id="submitting-a-pr"></a>

1. Ensure your branch is based on the latest `develop` branch
2. Push to your Fork repository
3. Submit a Pull Request to AppPorts' `develop` branch
4. Fill in required items in the PR template
5. Wait for CI checks to pass and Code Review

{% hint style="success" %}
**💡 Improve Merge Efficiency**

- Keep each PR focused on a single issue or feature
- Honestly fill in the test situation in the PR template
- Include screenshots for UI changes
{% endhint %}

## Welcome Contribution Areas <a href="#welcome-contribution-areas" id="welcome-contribution-areas"></a>

- Stability and performance improvements for core logic like `AppScanner`
- UI/UX optimization, especially improvements that feel native to macOS
- Synchronization and improvement of Chinese and English documentation
