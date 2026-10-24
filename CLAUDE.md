# AI Assistant Guide

This file provides guidance to AI coding assistants when working with code in this repository.

## Guiding Principles (MUST FOLLOW)

- **Keep it clear**: Write Swift code that is easy to read, maintain, and explain. Prefer clarity over cleverness.
- **Match the house style**: Reuse existing patterns, naming, and conventions found in the codebase.
- **Search smart**: Use glob/grep for codebase exploration before making assumptions about structure or patterns.
- **Log centrally**: Route all logging through `AppLogger.shared` with the right context—never use `print` in production code.
- **Always propose before executing**: Before making any changes, clearly explain your planned approach and wait for explicit user approval.
- **Build and test before completion**: Coding tasks are only complete after a successful `xcodebuild clean build` (Release). If the change touches a tested module, run the corresponding test suite.
- **Write conventional commits**: Commit small, focused changes using Conventional Commit messages (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`).
- **Build after every code change**: Verify compilation succeeds before delivering any code change.

## Project Overview

AppPorts is a native macOS app for migrating applications and data to external storage while preserving local access. Read the relevant source and project settings for current behavior and platform requirements.

## Build & Test Commands

If Xcode is installed outside `/Applications`, export `DEVELOPER_DIR` before running `xcodebuild`:
```bash
export DEVELOPER_DIR="/Volumes/<external-volume>/Applications/Xcode.app/Contents/Developer"
```

**Build** (Xcode project, no SPM):
```bash
xcodebuild clean build -scheme "AppPorts" -configuration Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED=NO
```

**Run all tests:**
```bash
xcodebuild test -scheme "AppPorts" -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED=NO
```

**Run a single test class** (e.g. `DataDirScannerTests`):
```bash
xcodebuild test -scheme "AppPorts" -destination 'platform=macOS' \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

**Run localization audit:**
```bash
xcodebuild test -scheme "AppPorts" -destination 'platform=macOS' \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/AppPortsDerived
```

The test target mixes XCTest and Swift Testing. Use the shared `AppPorts` scheme; there is no separate `AppPortsTests` scheme. Find relevant suites in `AppPortsTests/` and the test navigation in [CONTRIBUTING.md](CONTRIBUTING.md). Check affected callers as well as the changed module.

## Source Exploration

Read the relevant source, project settings, tests, and call sites before changing behavior. Derive the current architecture, supported platforms, versions, and implementation details from those files rather than maintaining a second description here. Search `.agents/notes/` for the reasons behind existing constraints; check each note against current code and later decisions.

## Safety Boundaries

- Validate source and destination boundaries. For managed custom directories, reject the home directory itself, symlinked source components, and overlapping configurations. Preserve real copies when local and external paths conflict. Symlinks, relative paths, or symlinked parents must never redirect cleanup to unrelated data.
- Migration failures must leave a recoverable state. A failure during signing or cleanup after migration must not cause retries to repeat the completed data migration.
- Protect unmounted managed mount points against accidental local writes. Persistently disable remounting before restoring local data. Keep active mount records separate from pending cleanup; report retained paths or volume identifiers when cleanup fails. Record-only removal must preserve all copies and refuse pending restore staging.
- Acquire the shared operation token and appropriate locks before file operations; release them on every completion/error path. Block conflicting actions while busy. Recheck running applications at execution time, including after waiting for locks or signature backups. Reject stale asynchronous scan results and process deferred refreshes after operations finish.
- Signing and signature backup must resolve to the real application, never the local portal. Missing targets, malformed portals, and cycles must fail safely. Parse legacy launcher metadata without executing the script.
- Preserve verified original signature backups and recovery copies. Scanning must not delete them. Signature restoration must not silently substitute ad-hoc signing when the original identity is unavailable.
- Keep sandboxed-container mount migration and explicitly confirmed classic migration separate. Outside explicitly confirmed classic mode, do not bypass sandbox checks, re-sign sandboxed apps, or replace container mount migration with symlinks. Preserve existing compatibility and recovery paths when changing either mode; do not use `/etc/fstab`.
- Keep local portal identity separate from the real app. Dock repair updates only existing pins and preserves order, tile identity, and unrelated entries; reject invalid targets and managed preferences, verify writes before refreshing Dock.
- Route production logging through `AppLogger.shared`. Serialize events with their detail fields, retain diagnostic subprocess time/output limits, redact usernames and storage paths in exports, and handle log-write failures without terminating the app.
- Use injectable system-operation boundaries and dedicated fixtures for tests. Do not alter the user's real Dock, installed apps, or business data as part of automated validation. Use the newly built app when manually checking UI behavior.

## Localization

- User-facing strings belong in `AppPorts/Localizable.xcstrings`. SwiftUI literals may use `LocalizedStringKey` APIs; AppKit and imperative strings must explicitly use `.localized`. Use format keys for dynamic text and meaningful localized labels even for hidden controls.
- Use `AppLanguageCatalog` as the language-list source of truth. Preserve placeholder consistency and avoid unrelated string-catalog reordering.
- When adding user-facing fields, status values, settings, alerts, errors, or labels, ask the maintainer whether to complete all supported translations in the same change. Otherwise document the fallback and follow-up. Run `LocalizationAuditTests` for user-facing copy changes; translation details are in [LOCALIZATION.md](LOCALIZATION.md).

## CI Configuration

- **PR smoke check** (`build.yml`): compilation-only build in Release mode. **Blocking.**
- **Tests (Advisory)** (`build.yml`): builds the Debug test bundle once, then runs the entire `AppPortsTests` target in three steps: app regression, isolated `ProcessCommandRunnerTests` timing checks, and localization. All results are advisory (non-blocking), including test-build failures. Timing tests run separately so process-heavy migration suites cannot distort their deadline assertions; no cases or time limits are removed.
- **Post-merge** (`post-merge-validation.yml`): app regression and process timing tests are mandatory; localization remains advisory. A successful Release build is checked for a valid app bundle and ZIP before uploading `AppPorts-Unsigned`. Runs on push to `main`.
- **Shared commands**: `.github/scripts/run-xcode-check.sh` defines the build and test invocations for both workflows. Test execution uses `test-without-building` after `prepare-tests`; keep the two steps on the same runner and DerivedData directory.
- **Diagnostics**: step summaries distinguish passed, failed, cancelled, and not-run checks. Advisory jobs can be green after a test failure, so read their summary. Logs and `.xcresult` bundles are uploaded for five days.
- **Run policy**: a newer commit cancels older checks for the same PR. Post-merge validation is retained for merged commits. Workflows use read-only repository permissions and can also be started manually.
- Run the full suite on a disposable macOS runner. Some integration tests register temporary app bundles with Launch Services. Do not set `APPPORTS_TEST_EXTERNAL_ROOT` or `APPPORTS_RENDER_UI_OUTPUT` in CI, or run the test process with `sudo`.
- Before updating `main` after changes to shared copy, scan, or transfer primitives, complete all three test checks and the Release clean build on that disposable runner. Focused migration suites and real-volume round trips do not cover every caller, including normal app termination. A temporary validation branch may run the existing manual workflow without opening a PR; require success for every check, including advisory localization, before advancing `main` to the tested commit.

## Branch Convention

- `main` — the shared development and release branch; create feature/fix branches from `main` and target `main` in Pull Requests.
- Commit style: `feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`, `test: ...`

## Pull Request Workflow

`CONTRIBUTING.md` is the public workflow entry point. Its recommended focused tests describe external-contributor expectations; AI assistants must run the corresponding suite when changing a tested module, as required below. Advisory CI changes merge enforcement, not this AI verification requirement. Documentation-only work uses the documentation checks in `User_docs/README.md`; it does not require an app build unless app source or build inputs also change. Keep shared contribution rules synchronized across the root Chinese/English guide, all three site translations, and affected PR-template fields.

When creating a Pull Request:

1. Ensure the branch is up-to-date with `main`
2. Fill in all required fields in the PR template
3. For app source or build-input changes, run `xcodebuild clean build` (Release) — this is mandatory. For documentation-only changes, run the relevant documentation checks.
4. If the PR touches a tested module, run the corresponding test suite
5. For UI changes, attach screenshots

## Issue Workflow

When reporting a bug or proposing a feature:

1. Search existing Issues first to avoid duplicates
2. For bugs, attach a diagnostic package (Menu → 日志 → 导出诊断包)
3. Significant feature changes, including migration strategy, data migration, and code signing, require discussion before implementation: use a [GitHub Issue](https://github.com/wzh4869/AppPorts/issues), or discuss with the owner in the [QQ group (384270587)](https://qm.qq.com/q/BhhRJ2rDz4). After a QQ discussion, the group owner publishes the conclusions in an Issue; obtain confirmation before development.

## Development Rules

- **Vibe Coding is accepted**, but code quality and correctness are the contributor's responsibility
- **Discuss large changes first**: major code churn, broad logic changes, migration strategy, data migration, and signing changes follow the Issue / QQ discussion process above. The group owner publishes QQ discussion conclusions in an Issue.
- **Never hardcode UI strings** — use i18n via `Localizable.xcstrings`
- **Never use `print`** — use `AppLogger.shared` for all logging
- **Always handle rollback** — migration operations must include rollback mechanisms on failure

## Agent Notes (Decision Records)

This project uses Agent Notes: **every non-trivial change must include a decision note in the same commit / PR as the code**.
The vendored `write-notes-like-deepseek` skill is the authority for when to write notes, where they belong,
required sections, lifecycle transitions, archiving, and verification gates. Before starting work, load
`.claude/skills/write-notes-like-deepseek/SKILL.md`; do not rely on memory.

Only two conventions are specific to this project; follow the skill for everything else:

- `.agents/notes/` is the only location for decision notes. `User_docs/` is the documentation site; do not write decision notes there.
- Verification command (the script is vendored with the skill):
  `npx tsx .claude/skills/write-notes-like-deepseek/scripts/verify-agent-note-tree.ts`
