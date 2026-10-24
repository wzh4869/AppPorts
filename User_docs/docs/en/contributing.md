# Contributor guide

Thank you for your interest in AppPorts. Contributions are welcome, whether fixing bugs, improving documentation, or adding features.

## Before you start {#section-1}

1. Search existing [Issues](https://github.com/wzh4869/AppPorts/issues) for duplicates.
   Discuss significant feature changes in an [Issue](https://github.com/wzh4869/AppPorts/issues) first, or join the [QQ group (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) to discuss them with the group owner. After a group discussion, the group owner publishes the conclusions in an Issue.
2. Fork and clone the project.
3. Create a feature (`feat/your-feature`) or fix (`fix/your-fix`) branch from `main`.

- The app runs on macOS 12 or later; this is not the minimum development environment. Development needs full Xcode, not just Command Line Tools, and the test toolchain must support Swift Testing. Prefer the Xcode used by current CI; find its exact version in the Actions Build environment log. The repository does not yet declare a verified minimum Xcode version.
- Open `AppPorts.xcodeproj`, select the shared `AppPorts` scheme and My Mac. The app does not use Swift Package Manager or third-party Swift dependencies. The unsigned command-line checks below need no release certificate; grant permissions for the operations you exercise when running locally.
- Check the active toolchain with `xcodebuild -version`. If Xcode is outside the default location, set `DEVELOPER_DIR` in your terminal, for example:

```bash
export DEVELOPER_DIR="/Volumes/<external-volume>/Applications/Xcode.app/Contents/Developer"
```

## Development approach {#section-2}

### Vibe coding {#section-3}

AppPorts accepts AI-assisted development with tools such as Cursor, GitHub Copilot, and Claude. These tools can improve productivity, but **the contributor remains responsible for code quality and correctness**.

- **AI assistants must follow the root `CLAUDE.md`**, which defines coding guidelines, safety boundaries, build commands, and workflow. Explicitly ask the assistant to read it first if it does not do so automatically.
- Review generated code yourself for consistency with the project style.
- AI does not replace understanding macOS behavior. Manually validate filesystem, signing, and permission logic.
- **Core-feature changes**, including migration strategies, data migration, and code signing, follow the same discussion process and require confirmation before development.

### Code style {#section-4}

- Follow Swift conventions and the existing project style.
- Write clear Swift documentation comments for complex logic.
- Use `LocalizedStringKey` APIs for SwiftUI literals and `.localized` for AppKit/API strings.

## Testing requirements {#section-5}

::: warning PRs must pass the Release build
CI requires the compilation smoke check. Focused tests provide advisory feedback and are not automated PR merge gates.
:::

**Separate merge gates from verification responsibilities:** the automated PR merge gate remains the Release build. External contributors are encouraged to run tests for affected modules and report passed, failed, skipped, or not-run checks and reasons in the PR. AI assistants must also follow `CLAUDE.md`: run the relevant tests when changing a module with existing coverage. Advisory means CI does not block merging; investigate and explain whether failures relate to the change.

Run the full suite on a disposable macOS runner; some integration tests register temporary apps with Launch Services. Do not run tests with `sudo` or set `APPPORTS_TEST_EXTERNAL_ROOT` or `APPPORTS_RENDER_UI_OUTPUT` in CI. Use dedicated test data for real external-drive experiments and distinguish them from default automated checks.

### Required: compilation smoke check {#section-6}

Every PR must pass a Release build in Xcode. This is a hard merge requirement:

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

### As applicable: focused tests {#section-7}

External contributors are encouraged to run the relevant focused tests when a PR changes these modules. CI also runs them in advisory mode: they provide feedback without blocking merges.

#### Data-directory tests {#section-8}

For `DataDirMover`, `DataDirScanner`, or related migration logic:

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

#### App-migration tests {#section-9}

For `AppMigrationService`, `AppScanner`, or app-migration logic:

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

#### Logging tests {#section-10}

For `AppLogger` or diagnostics:

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

#### Localization audit {#section-11}

For user-visible text, menus, dialogs, settings, and errors:

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

### Test overview {#section-12}

| Suite | Area | When to run |
| --- | --- | --- |
| Compilation smoke check | Entire project | **Required** by CI |
| `DataDirMoverTests` | Data migration | Changes to `DataDirMover` |
| `DataDirScannerTests` | Data scanning | Changes to `DataDirScanner` |
| `AppMigrationServiceTests` | App migration | Changes to `AppMigrationService` |
| `AppScannerTests` | App scanning | Changes to `AppScanner` |
| `AppLoggerTests` | Logs and diagnostics | Changes to `AppLogger` |
| `LocalizationAuditTests` | Localization | User-visible text changes |

Other test entry points (not exhaustive; include affected callers):

| Change area | Test entry points |
| --- | --- |
| Custom folders | `CustomDirScannerTests`, `CustomDirRecoveryEligibilityTests` |
| File copying and ownership | `FileCopierTests`, `TreeCopySessionTests`, `TreeCopyOwnershipTests` |
| Container mount migration | `ContainerVolumeMigratorTests`, `ContainerMountSafetyTests` |
| Signing and repair | `CodeSignerTests`, `SignatureOperationTests`, `SignatureRepairSafetyTests` |
| Transfer records and recovery | `DataTransferStoreTests`, `DataTransferRecoveryTests`, `AppTransferTransactionTests` |
| Operation state and Dock | `AppOperationStateTests`, `DockShortcutServiceTests` |
| Subprocess deadlines | `ProcessCommandRunnerTests` (run separately) |
| Updates and sponsors | `UpdateCheckerTests`, `SponsorsTests` |

After one Debug test build, CI runs the full suite in separate app-regression, process-timing, and localization steps. All are advisory on PRs. After merging to `main`, app regression and process timing must pass; localization remains advisory. CI then builds Release, validates the app bundle and ZIP, and uploads the unsigned app. A green advisory job does not guarantee passing tests: read the step summary. Logs and `.xcresult` artifacts are kept for five days. New commits cancel older checks for the same PR.

See the [shared CI script](https://github.com/wzh4869/AppPorts/blob/main/.github/scripts/run-xcode-check.sh) for full commands: run `prepare-tests`, then `regression`, `process`, and `localization` on the same runner and DerivedData; `release` performs the Release clean build. Set `CI_DERIVED_DATA_PATH` and `CI_RESULTS_DIR` to dedicated validation directories before invoking it; use a fresh results directory on repeat runs to avoid existing `.xcresult` conflicts. Before advancing `main` after shared copy, scan, or transfer changes, also complete the full isolated-runner validation required by `CLAUDE.md`.

## Localization {#section-13}

- External contributors may defer complete translations, but code must still use the localization system: add new keys to `AppPorts/Localizable.xcstrings`, use `.localized` for AppKit/API copy, format keys for dynamic text, and `AppLanguageCatalog` for the language list.
- If translations are deferred, list affected text, languages, actual fallback display, and follow-up plans in the PR. Do not hide missing translations by copying English, deleting audit assertions, or broadening exemptions. AI assistants confirm the translation scope with the maintainer as required by `CLAUDE.md`.
- Limit string-catalog edits to relevant keys and translations; avoid unrelated catalog reordering. For menu, dialog, settings, error, status, and onboarding changes, inspect the actual `zh-Hans` and `en` display where possible.

See [LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Commit conventions {#section-14}

- Discuss significant feature changes in an [Issue](https://github.com/wzh4869/AppPorts/issues) first, or join the [QQ group (384270587)](https://qm.qq.com/q/BhhRJ2rDz4) to discuss them with the group owner. After a group discussion, the group owner publishes the conclusions in an Issue.
- Keep each PR focused on one problem or feature.
- Recommended commit prefixes: `feat:` for features, `fix:` for bugs, `docs:` for documentation, `refactor:` for restructuring, and `test:` for testing.

**Decision notes:** Non-trivial changes (behavior, architecture, cross-file contracts, process/tooling, test strategy, or storage formats) require a decision note in the same commit / PR as the code. Search existing decisions in `.agents/notes/` first; update facts in their owning note and follow the [vendored skill](https://github.com/wzh4869/AppPorts/blob/main/.claude/skills/write-notes-like-deepseek/SKILL.md) for new tradeoffs. Mechanical edits are exempt. Keep notes only in `.agents/notes/`, not `User_docs`; the skill owns format, lifecycle, and the three validation commands. Link the note in the PR or explain why it is not applicable.

## Submit a PR {#section-15}

1. Base your branch on the latest `main`.
2. Push to your fork.
3. Open a Pull Request targeting AppPorts' `main` branch.
4. Complete required fields in the PR template.
5. Wait for CI and code review.

::: tip Help review move smoothly
- Keep each PR focused on one issue or feature.
- Report testing accurately in the template.
- Include screenshots for UI changes.
:::

The root [CONTRIBUTING.md](https://github.com/wzh4869/AppPorts/blob/main/CONTRIBUTING.md) is the contribution-workflow entry point. When changing shared rules, synchronize its Chinese and English sections, the site's Simplified Chinese / Traditional Chinese / English guides, and affected PR-template fields. `AGENTS.md` / `CLAUDE.md` govern AI execution, `User_docs/README.md` owns site-operation details, and the vendored skill owns note conventions.

## Welcome contribution areas {#section-16}

- Stability and performance of core logic such as `AppScanner`.
- UI/UX improvements, especially native macOS behavior.
- Keeping Simplified Chinese, Traditional Chinese, and English documentation complete and synchronized.

For documentation-site changes, first read [User_docs/README.md](https://github.com/wzh4869/AppPorts/blob/main/User_docs/README.md) and [User_docs/AGENTS.md](https://github.com/wzh4869/AppPorts/blob/main/User_docs/AGENTS.md). In `User_docs`, use a compatible Node.js LTS and run `npm ci` and `npm run docs:dev`; refresh edited Markdown with `npm run docs:prepare`. Before submitting, run `npm run docs:build`, `npm run docs:typecheck`, and `npm run docs:check` in that order.

Keep Simplified Chinese source, Traditional Chinese, and English translations synchronized, including chapter IDs and their order. Do not edit or commit generated `.content/`, `public/`, `.next/`, or `out/`. Inspect changed pages in all three languages on desktop and mobile; for site-function changes also check search, themes, language switching, and Markdown export. Validate documentation-only contributions with documentation checks, app-source changes with the app build and relevant tests, and app translations with localization auditing and display checks. Building does not publish the site.
