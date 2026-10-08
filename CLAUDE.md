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

AppPorts is a native macOS desktop app (Swift/SwiftUI) that migrates applications from `/Applications` to external storage while keeping a functional local "portal" via Stub Portal (launcher script). It also supports migrating data directories (`~/Library/` subfolders and dot-folders like `~/.npm`) and user-selected custom folders. Minimum deployment target: macOS 12.0 (Monterey).

## Build & Test Commands

If Xcode is installed outside `/Applications`, export `DEVELOPER_DIR` before running `xcodebuild`:
```bash
export DEVELOPER_DIR=/Volumes/hano/Applications/Xcode.app/Contents/Developer
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
xcodebuild test -scheme "AppPorts" -destination 'platform=macOS,arch=arm64' \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/AppPortsDerived
```

### Test Suites Overview

| Test Suite | Module | When to Run |
|------------|--------|-------------|
| `DataDirMoverTests` | Data directory migration | When touching `DataDirMover` |
| `DataDirScannerTests` | Data directory scanning | When touching `DataDirScanner` |
| `CustomDirScannerTests` | Custom directory configs/scanning/validation | When touching `CustomDirModels`, `CustomDirScanner`, or custom directory UI |
| `AppMigrationServiceTests` | App migration | When touching `AppMigrationService` |
| `AppScannerTests` | App scanning | When touching `AppScanner` |
| `AppLoggerTests` | Logging & diagnostics | When touching `AppLogger` |
| `LocalizationAuditTests` | Localization | When touching user-facing copy |
| `UpdateCheckerTests` | Automatic/manual update lookup, fallback, and result states | When touching `UpdateChecker` or About update behavior |
| `FileCopierTests` | Network concurrency, progress, metadata, cancellation, and cleanup | When touching `FileCopier` |
| `AppOperationStateTests` | Operation tokens and shared busy state | When touching operation gating |
| `AppRunningStateTests` | Real-app running detection, paths, and bundle identifiers | When touching pre-operation running checks |
| `DockShortcutServiceTests` | Existing pins, bookmarks, concurrent edits, and reload scheduling | When touching Dock synchronization |
| `CodeSignerTests` / `DataMigrationWorkflowTests` | Real-app resolution, signing, locks, sandbox refusal, and ordered data migration | When touching signing or data migration workflow |
| `ContainerVolumeMigratorTests` | Mount migration with a fake `diskutil`: volume creation, in-place mount, rollback, restore, remount | When touching `ContainerVolumeMigrator`, `DiskUtility`, or `ContainerMountStore` |
| `MigrationPreferencesTests` | Classic-mode gate and reminder dismissal persistence | When touching `MigrationPreferences` |
| `MigrationSigningIntegrationTests` | Real signed bundles and app/data migration round trips | When changing migration and signing together |

The test target mixes XCTest and Swift Testing. Use the shared `AppPorts` scheme for both; there is no separate `AppPortsTests` scheme. Dock tests inject a preference store and reload action so they do not alter the user's real Dock.

## Architecture

### Directory Structure

```
AppPorts/
├── AppPorts.xcodeproj/             # Xcode project (no SPM, no external deps)
├── AppPorts/                       # Main source
│   ├── Appports.swift              # @main entry point + AppDelegate
│   ├── ContentView.swift           # Main window and top-level tab routing
│   ├── WelcomeView.swift           # First-launch welcome screen
│   ├── AboutView.swift             # Standalone About window, contributors, and updates
│   ├── Localizable.xcstrings       # String catalog (22 languages)
│   ├── Models/
│   │   ├── AppModels.swift         # AppItem, AppMoverError, AppContainerKind
│   │   ├── DataDirItem.swift       # DataDirItem, DataDirType, DataDirPriority
│   │   ├── ContainerMountModels.swift # ContainerMountRecord (mount migration record)
│   │   ├── MigrationPreferences.swift # Classic-mode gate, repair-reminder dismissals
│   │   ├── CustomDirModels.swift   # CustomDirConfig, validation, display entries
│   │   └── AppLanguageOption.swift # Language catalog (AppLanguageCatalog)
│   ├── Views/
│   │   ├── DataDirsView.swift      # Tool dirs + app data management
│   │   ├── CustomDirsView.swift    # User-selected folder migration tab
│   │   ├── AppStoreSettingsView.swift # Settings sheet (incl. classic data migration mode)
│   │   ├── SignatureRepairSheet.swift # Four-step repair panel for apps with replaced signatures
│   │   └── Components/
│   │       ├── AppIconView.swift   # Async app icon loader
│   │       ├── AppRowView.swift    # App list row + context menu
│   │       ├── DataDirRowView.swift # Data dir row + tree indentation
│   │       ├── CustomDirRowView.swift # Custom folder row
│   │       ├── StatusBadge.swift   # Status pill badges (link/framework/type)
│   │       ├── ProgressOverlay.swift # Migration progress overlay
│   │       └── HelpButton.swift    # Popover help button
│   ├── Services/
│   │   ├── AppMigrationService.swift # App migration, portal creation, and Dock synchronization
│   │   ├── AppLogger.swift         # Serialized logging + redacted diagnostic export
│   │   ├── AppOperationState.swift # Shared operation token and busy state
│   │   ├── ContainerMountStore.swift # Persists mount migration records (container-mounts.plist)
│   │   ├── ContainerMountAgentInstaller.swift # Login agent that remounts container volumes (`--mount-agent`)
│   │   ├── DataMigrationWorkflow.swift # Ordered signature backup → migration → signing
│   │   ├── DockShortcutService.swift # Repair existing Dock pins and bookmarks
│   │   └── CodeSigner.swift        # Real-app resolution, entitlements/sandbox check, signing backup/restore and verification
│   └── Utils/
│       ├── AppRunningState.swift   # Match running real applications before operations
│       ├── AppScanner.swift        # App scanner actor
│       ├── ContainerVolumeMigrator.swift # Mount migration actor for sandboxed apps' container data
│       ├── DataDirScanner.swift    # Data dir scanner actor
│       ├── DataDirMover.swift      # Data dir migration, conflict checks, and recovery
│       ├── CustomDirScanner.swift  # Custom folder status scanner
│       ├── DiskUtility.swift       # diskutil/statfs wrapper with injectable command runner
│       ├── FileCopier.swift        # Metadata-preserving copy with bounded network concurrency
│       ├── FolderMonitor.swift     # DispatchSource filesystem watcher
│       ├── LanguageManager.swift   # Global i18n manager + String.localized
│       ├── UpdateChecker.swift     # GitHub API/Atom + official update feed
│       └── LocalizedByteCountFormatter.swift
├── AppPortsTests/                  # Unit tests
│   ├── AppMigrationServiceTests.swift
│   ├── AppScannerTests.swift
│   ├── CustomDirScannerTests.swift
│   ├── DataDirScannerTests.swift
│   ├── DataDirMoverTests.swift
│   ├── AppLoggerTests.swift
│   ├── LocalizationAuditTests.swift
│   ├── UpdateCheckerTests.swift
│   ├── AppOperationStateTests.swift
│   ├── AppRunningStateTests.swift
│   ├── DockShortcutServiceTests.swift
│   ├── FileCopierTests.swift
│   ├── CodeSignerTests.swift        # Includes DataMigrationWorkflowTests
│   └── MigrationSigningIntegrationTests.swift
└── User_docs/                      # VitePress documentation site
```

### Build Settings

| Setting | Value |
|---------|-------|
| Bundle ID | `com.shimoko.AppPorts` |
| Marketing Version | `1.9.0` (`MARKETING_VERSION` in `project.pbxproj`) |
| Deployment Target | macOS 12.0 (Monterey) |
| Swift Version | 5.0 |
| App Sandbox | **Disabled** (required for /Applications access) |
| Hardened Runtime | Enabled |
| External Dependencies | **None** (pure Apple frameworks) |
| Info.plist | Auto-generated (`GENERATE_INFOPLIST_FILE = YES`) |
| Entitlements | None (no sandbox) |
| UI Framework | SwiftUI views with AppKit window management (no storyboards/xibs) |

Release notes for the previous `1.8.1` update live in `RELEASE_NOTES_1.8.1.md`; the upcoming `1.9.0` notes live in `RELEASE_NOTES_1.9.0.md`. The project now declares version `1.9.0`, build `21`. The upcoming notes are a draft and do not create a release tag. Keep the Chinese and English notes aligned and begin each with a short user-facing summary. Icon explorations under `design/icon-exploration/` are drafts, not a shipped app-icon replacement.

### Core Pattern: Actor-based Concurrency

The following services use Swift actors to isolate scanning, copying, data migration, and signing work:

- `AppScanner` — scans `/Applications` and external drive for apps
- `DataDirScanner` — scans `~/Library/` and known dot-folders for associated data
- `DataDirMover` — migrates/restores data directories
- `CustomDirScanner` — scans saved custom folder migration configs
- `FileCopier` — file copy with progress callback
- `CodeSigner` — ad-hoc code signing with original signature backup/restore

### Component Dependency Graph

```
    Appports.swift (@main) ──► AppDelegate ──► AboutWindowController ──► AboutView
         │
    ┌────┴────┐
    ▼         ▼
WelcomeView  ContentView
             │
    ┌────────┼────────────┬──────────────┐
    ▼        ▼            ▼              ▼
 Apps UI  DataDirsView  CustomDirsView  Settings
    │        │            │
    ▼        ▼            ▼
┌───────────────────────────────────────────┐
│           Services & Utils                │
│                                           │
│  AppMigrationService ──► FileCopier       │
│       │                   CodeSigner      │
│       ▼                                   │
│  AppScanner ─────────► AppItem            │
│                                           │
│  DataDirScanner ─────► DataDirItem        │
│  DataDirMover ───────► FileCopier         │
│                                           │
│  CustomDirScanner ───► CustomDirPair      │
│                          CustomDirConfig  │
├───────────────────────────────────────────┤
│        Cross-Cutting (Singletons)         │
│  AppLogger.shared ◄── used everywhere     │
│  LanguageManager.shared ◄── all views     │
│  FolderMonitor ◄── ContentView            │
│  UpdateChecker ◄── ContentView / AboutView│
│  AppOperationState.shared ◄── operation UI│
└───────────────────────────────────────────┘
```

### App Lifecycle

1. **Launch** → `AppMoverApp` (@main) → `AppLogger.shared.logLaunchSession()` logs system diagnostics
2. **First launch** → `WelcomeView` (feature cards, Full Disk Access permission check, language switcher)
3. **Main app** → `ContentView` with three top-level tabs:
   - **Apps tab**: `HSplitView` — local apps (left) / external apps (right). Multi-select → batch migrate/link/restore
   - **Data Dirs tab**: `DataDirsView` with two sub-tabs — Tool Dirs (`~/.npm`, `~/.m2`, `.gradle`, `.android`, `.pub-cache`, etc.) and App Data (`~/Library/` subdirs)
   - **Directory Migration tab**: `CustomDirsView` for arbitrary user folders under the current user's home directory
4. **Background**: `FolderMonitor` watches `/Applications`, external drive, and user-configured custom local app scan dirs with 1s debounce for auto-rescan
5. **Menu bar**: Language switcher (22 languages), log management, diagnostics export, and a reusable standalone About window. `@MainActor AppDelegate` retains `AboutWindowController`; About can be opened even after the main window is closed.

### File Responsibilities

#### Entry Point & Top-Level Views

| File | Role |
|------|------|
| `Appports.swift` | `@main` entry, `AppDelegate` (prevents terminate on last window close), menu bar commands, `LanguageManager` locale injection |
| `ContentView.swift` | Main view: app list management, migration/link/restore operations, top-level tab switcher (`apps`, `dataDirs`, `customDirs`), FolderMonitor integration, debounced rescanning, custom local app scan directories (persisted via UserDefaults, with per-directory FolderMonitor), Stub Portal version sync on rescan, inline helper views (`HeaderView`, `ActionFooter`, `EmptyStateView`, `TabButton`). Real-path resolution for linked apps (`resolveRealAppURL` delegates to `CodeSigner.resolveAppURL(at:)`). URL-based signing helpers (`performResign(at:bundleID:)`, `performBackupSignature(at:bundleID:)`, `getBundleIdentifier(from:)`) for data directory migration signing flow |
| `WelcomeView.swift` | First-launch screen: feature cards, Full Disk Access guidance, language switcher |
| `AboutView.swift` | Standalone About window: app icon, version/build, project links, text-only contributor links (GitHub API with disk cache and built-in fallback), manual update check, copyright, and Apache License 2.0 link |
| `DataDirsView.swift` | Built-in data directory UI: tool dirs and app-associated data. Passes the selected external root into scanner calls so missing local entries can surface as `待接回`. |
| `CustomDirsView.swift` | Custom folder migration UI: two-pane local/external list, add sheet, batch migrate/relink/restore, progress overlay on the parent view. Reuses `DataDirMover` through `CustomDirEntry.dataDirItem`. |

#### Models

| File | Key Types |
|------|-----------|
| `AppModels.swift` | `AppItem` (name, path, status, flags: isSystemApp/isRunning/isAppStoreApp/isIOSApp/isResigned/isElectronApp/isSparkleApp/hasSelfUpdater/needsLock, size, containerKind), `AppMoverError`, `AppContainerKind` (.standaloneApp/.singleAppContainer/.appSuiteFolder) |
| `DataDirItem.swift` | `DataDirItem` (name, path, type, priority, status, size, linkedDestination, tree children), `DataDirType` (12 types), `DataDirPriority` (.critical/.recommended/.optional), `DataDirError` |
| `CustomDirModels.swift` | `CustomDirConfig` (local path, external base, computed external destination), `CustomDirStatus`, `CustomDirEntry`, `CustomDirPair`, `CustomDirValidator`, `CustomDirLocalOpenPanelGuard` |
| `AppLanguageOption.swift` | `AppLanguageOption`, `AppLanguageCatalog` — 22 selectable languages: 3 primary, 17 AI-translated, Braille, and Martian Chinese |

#### Services

| File | Role |
|------|------|
| `AppMigrationService.swift` | Core migration engine: move-and-link (copy→delete→create portal), link app, delete link, move back. Portal strategy selection, self-updater detection (Sparkle/Electron/custom), uchg lock/unlock, Finder-based MAS app deletion, macOS 15.1+ MAS external install, rollback on failure. Stub Portal version sync (`refreshStubPortal`) updates local Info.plist when external app is updated via App Store, with Launch Services refresh (`lsregister -f`) |
| `AppLogger.swift` | Singleton logger: file logging with rotation (2MB default), multi-level (INFO/ERROR/DIAG/DISK/PERF/TRACE/WARN), system diagnostics (hardware/software/disk), operation summaries (JSON), diagnostic package export (ZIP with redacted logs) |
| `AppOperationState.swift` | `@MainActor` singleton with `begin()`/`finish(_:)` tokens. Blocks overlapping operations across tabs/windows and keeps busy state alive across view reconstruction. Only the matching token may finish an operation. |
| `DataMigrationWorkflow.swift` | Awaits signature backup → data migration → re-signing when signing is requested. A signing failure after migration is reported distinctly as `Failure.signingFailed`; do not automatically migrate the data again. |
| `DockShortcutService.swift` | Updates existing `com.apple.dock` `persistent-apps` entries and bookmarks, preserving pin positions, tile identity, and unrelated entries. Re-reads preferences to handle concurrent edits, verifies writes, and coalesces Dock refreshes. |
| `CodeSigner.swift` | Actor: ad-hoc re-signing (`codesign --force --sign -`), signature backup/restore via plist files in `~/Library/Application Support/AppPorts/signature-backups/`, resolves portals to the real application, temporarily unlocks nested items, deep-signs and verifies, restores original immutable flags, and handles root-installed app ownership repair via AppleScript with retry logic |

#### Utils

| File | Role |
|------|------|
| `AppRunningState.swift` | Resolves the real app, then matches a fresh running-app snapshot by normalized path or a nonempty bundle identifier. Missing identifiers alone never establish a match; a matching path still does. |
| `AppScanner.swift` | Actor: scans /Applications, external dirs, and user-configured custom local app scan dirs. Detects portal types (wholeApp/deepContents/stubPortal), system/running/AppStore/iOS/Electron/Sparkle/self-updater apps, resigned status, folder containers, deduplication by bundleID/name, macOS 15.1+ MAS external scanning. Info.plist in-memory cache (per-scan) reduces redundant disk reads. `codesign -dvv` timeout protection (10s). `calculateDirectorySize` has 500k file count safety cap. `resolveExternalRealApp(from:)` — parses stub portal launcher or symlink to find real external app for resigned status checking |
| `DataDirScanner.swift` | Actor: scans 30+ known dotFolders (npm, maven, Gradle, Android, Flutter/Dart, bun, conda, ollama, torch, whisper, cursor, vscode, docker, etc.), ~/Library/ subdirs matching by bundleID/appName, tree construction, status detection, managed link metadata verification. `scanKnownDotFolders(externalRootURL:)` surfaces missing local tool dirs as `待接回` when the canonical external directory exists. Bundle ID suffix extraction filters generic TLD words (app, com, org, etc.) to avoid over-matching container directories |
| `CustomDirScanner.swift` | Actor: scans saved `CustomDirConfig` entries and returns local/external `CustomDirPair` state (`本地`, `已链接`, `待接回`, `孤立链接`, `目标冲突`, `未找到`). |
| `DataDirMover.swift` | Actor: migrate (copy→backup local source→symlink), restore (delete symlink→copy back), create link, normalize managed link, `.appports-link-metadata.plist` management, conflict detection, interrupted migration recovery, protected path detection. Used by both built-in data directories and custom directory migration. |
| `FileCopier.swift` | Actor: recursive directory copy preserving permissions/xattrs/timestamps, bounded file concurrency (4 for network volumes, 1 locally), progress based on existing size estimates with byte/file/time thresholds, symlink handling, socket skipping, retry and safe partial-copy cleanup |
| `FolderMonitor.swift` | DispatchSource (kqueue) filesystem watcher with 1s debounce |
| `LanguageManager.swift` | Singleton `ObservableObject`: language selection (UserDefaults), `Locale` for SwiftUI environment, `String.localized` extension with .lproj fallback chain |
| `UpdateChecker.swift` | Checks GitHub API (with Atom fallback) and the official `latest.json` feed concurrently, compares versions, and returns explicit manual-check results |

### Migration Strategies

AppPorts picks a local portal strategy per app:

1. **Stub Portal** (default for all `.app` bundles): creates a minimal fake `.app` shell with a bash launcher script that `open`s the real external app. No symlinks, no arrow icon, self-updaters cannot penetrate. Two sub-variants:
   - **macOS Stub Portal**: for native macOS apps
   - **iOS Stub Portal**: for iOS apps on Mac (icon extraction from `WrappedBundle/`)

2. **Whole App Symlink** (folders/suites, non-`.app` paths): symlinks the entire `.app` bundle or directory.

3. **Deep Contents Wrapper** (legacy, deprecated): recognized when scanning, restoring, or signing old migrations. No longer used for new portals.

`AppMigrationService.preferredPortalKind(for:)` decides which strategy to use by inspecting the bundle.

### Self-Updater Detection

AppPorts detects self-updating apps and applies lock protection (`chflags -R uchg`) to prevent external copies from being modified:

- **Sparkle**: `Sparkle.framework` / `Squirrel.framework`, Info.plist keys (`SUFeedURL`, etc.)
- **Electron**: `Electron Framework.framework`, `app-update.yml`
- **Custom updaters**: `LaunchServices/`, `KSProductID`, binaries containing "update"

### Data Directory Link Management

`DataDirScanner` and `DataDirMover` both track managed symlinks using `.appports-link-metadata.plist` sidecar files in the external destination. This distinguishes AppPorts-created links from pre-existing symlinks. Status values: `本地` (local), `已链接` (linked), `待接回` (awaiting relink), `现有软链` (pre-existing symlink), `待规范` (needs normalization).

Known tool directories use canonical external destinations under `<externalRoot>/<DataDirType.rawValue>/<lastPathComponent>`, for example `<externalRoot>/工具目录/.gradle`. `scanKnownDotFolders(externalRootURL:)` should hide items that are missing locally and externally, but surface `待接回` when the canonical external directory already exists.

Custom directory migration stores configs in `UserDefaults` under `customDirConfigs`. A config keeps the real local source and an external base directory; the actual destination is `externalBaseURL / localURL.lastPathComponent`. Local sources must be real directories under the current user's home, cannot be the home directory itself, cannot pass through symlinked path components, and cannot overlap with another managed custom directory.

### Sandboxed Apps and Mount Migration

Sandboxed apps (real app's entitlements contain `com.apple.security.app-sandbox`) cannot follow symlinks out of `~/Library/Containers/` or `~/Library/Group Containers/`: the kernel checks the resolved path. Ad-hoc re-signing removes the sandbox but also breaks container ownership, and on macOS 27 such apps may fail to launch (confirmed: WeChat, whose stored TCC code requirement no longer matches; QQ Music still runs). Verified experiments live under `User_docs/docs/research/` (`sandbox-symlink.md`, `sandbox-mountpoint.md`, `unplug-test.md`); user-facing docs are `datamigrae/mount-migration.md`, `why-apfs.md`, and `macos-27.md`.

- `CodeSigner.isSandboxed(at:)` / `entitlements(at:)` read entitlements via `codesign -d --entitlements`. `CodeSigner.sign` throws `sandboxedApplication` before touching the bundle; `restoreSignature` throws `identityUnavailable` instead of degrading to ad-hoc. `AppPorts-ReSign.sh` skips sandboxed apps.
- Every migratable item under `Containers` / `Group Containers` gets `DataDirItem.requiresMountMigration = true` regardless of the main app's entitlements (the container's owner may be a sandboxed widget/extension, and already re-signed apps must not be symlinked again); the row shows “挂载迁移” instead of “迁移”. `DataDirScanner.isSandboxed(_:)` only decides whether re-signing is refused: `DataDirsView` never re-signs sandboxed apps regardless of the toggle or alert choice.
- `ContainerVolumeMigrator` (actor) creates an APFS volume in the external drive's container (`diskutil apfs addVolume`), copies data through `FileCopier`, and mounts the volume at the original directory (`diskutil mount -mountPoint`). Records live in `ContainerMountStore` (`~/Library/Application Support/AppPorts/container-mounts.plist`); the volume root carries `.appports-mount-metadata.plist`. Unmounted mount points are kept at mode 000 so the app sees an empty directory rather than writing local data. Statuses: `已挂载`, `待挂载`, `卷丢失`.
- Mounting requires Full Disk Access and an APFS external drive. First launch after migration triggers the system “removable volume” TCC prompt; platform apps under `/System` are silently denied and are not supported.
- Remount runs on launch and on `NSWorkspace.didMountNotification`; `ContainerMountAgentInstaller` installs a LaunchAgent that runs `AppPorts --mount-agent` at login (handled in `AppMoverApp.init` before any UI). Do not use `/etc/fstab`.
- `DiskUtility` takes an injectable `ShellCommandRunning`; tests use `FakeDiskCommandRunner` and never touch real disks.
- Keep active mount records separate from pending cleanup records. Restore must persistently disable remounting before switching to local data; cleanup failure is partial success and must show the retained path or volume UUID. Retry never repeats the data migration. An explicit record-only removal preserves all copies and is refused while restore staging is still pending.
- Each outer mount operation owns a separate `OperationLock` instance; the instance-level acquisition is intentionally idempotent. Recheck running applications after waiting for that lock and after signature backups, immediately before moving data.
- **Classic data migration mode** (`MigrationPreferences.classicDataMigrationKey`, default off; not version-gated, `MigrationPreferences.isMacOS27OrLater` only picks wording): container items also offer symlink “迁移”, the container re-sign alert returns, `CodeSigner.sign(allowSandboxed: true)` is permitted after a per-app confirmation, the “迁移后重签名” toolbar toggle reappears, and `AppPorts-ReSign.sh` stops skipping sandboxed apps. Outside classic mode, “整理/接回/链接详情” are refused for container items.
- **Signature-replaced detection**: `AppScanner` reads the signature backup via `CodeSigner.originalSigningIdentity`; a developer-identity backup plus a current ad-hoc signature sets `AppItem.signatureReplaced`. Scanning never deletes signature backups. Re-signing saves a verified full original application and operates on a work copy; restoration atomically replaces the real app from that snapshot without a developer private key. Legacy identity-only records require a matching official original app. A verified official update with the same developer identity gets a new snapshot; the prior record and snapshot are archived. UI: red “签名已替换” badge, one startup reminder (dismissals stored under `MigrationPreferences.dismissedSignatureRepairKey`), and `SignatureRepairSheet` (restore container data → move app back if reinstalling → restore original signature or reinstall → optional mount migration; never deletes anything).

### Real-Path Resolution for Linked Apps

For linked apps, signing must target the real application package, not the local portal. `ContentView.resolveRealAppURL(for:)` delegates to `CodeSigner.resolveAppURL(at:)`, which supports:

- Whole-app symlinks, including relative targets.
- Stub path files (`Contents/Resources/real_app_path.txt`).
- Legacy bash launchers with a literal `REAL_APP='...'` assignment; scripts are parsed, never executed.
- Legacy Deep Contents Wrappers, resolved to the external `.app` package.

Missing targets, malformed portals, and cycles fail before signing or backing up a stub. `AppScanner.resolveExternalRealApp(from:)` is used for scanning/resigned-status display; it is not the signing authority. Signing entry points also resolve the real path themselves.

### Dock Identity and Repair

- Local stubs keep their own bundle identifiers ending in `.appports.stub`. Do not make the stub impersonate the external app to hide duplicate Dock icons.
- Migration, relinking, and restoration synchronize existing Dock pins through `DockShortcutService`; they do not add pins for apps the user has not pinned.
- `AppMigrationService.repairDockShortcuts(for:)` supports the local app row's “Repair Dock Icon” action for older migrations.
- Updated pins point directly at the real app. Preserve their position, tile identity, and unrelated Dock entries; replace and validate the bookmark for the new target. Reject invalid targets and managed preferences; refresh Dock only after a verified write.
- Launching a migrated app from its repaired Dock pin requires the external drive. Changing the independent local stub does not modify the external app bundle.

### About Window and Updates

- The published `https://docs-appports.shimoko.com/sponsors.json` is authoritative: every successful response replaces the sponsor list and disk cache, including an empty list, regardless of `updatedAt`. Only request or decoding failures fall back to the last successful cache, then the bundled JSON. `updatedAt` is informational, not a source-priority rule. The repository-root `sponsors.json` supplies both the Xcode bundle resource and the documentation site's root JSON; local edits reach online users after deploying the documentation site. Rebuilding AppPorts only updates its bundled fallback.
- A sponsor's `link` is optional (empty or omitted). Display an unlinked name as plain text. Amounts remain website-only, with up to two decimal places. Keep the sponsor acknowledgments in both READMEs in sync, and run `SponsorsTests` after changes to sponsor loading.

- `AboutWindowController` hosts SwiftUI in a reusable, resizable AppKit window on macOS 12+. Closing About does not release it; opening it again restores the same window, including from a minimized state.
- Show the app icon, name, description, version/build, project links, text-only contributor links, update section, copyright, and Apache License 2.0 link. Contributors must not have avatars or decorative icons.
- Keep the existing GitHub contributor request, 10-second timeout, disk cache, and built-in fallback list.
- `AboutView` and `AboutUpdateSection` explicitly observe `LanguageManager.shared`. Their `.localized` values are ordinary strings; changing only the root environment locale is insufficient to guarantee every section is recomputed.
- `UpdateChecker.checkForUpdatesResult()` returns `.available(AppUpdateInfo)`, `.upToDate`, or `.failed`. At least one enabled source must complete successfully before reporting up to date. Disabled sources and malformed versions do not count as success.
- `checkForUpdates()` remains the quiet automatic-check API: it returns an update only when one is available. GitHub API failures fall back to Atom; the official feed is checked in parallel.
- Manual checks disable the button and show progress, then display the outcome and available download links. This is a check with download links, not an automatic installer.
- For UI changes, verify opening/closing/reopening About, opening it with the main window closed, language changes in both the body and update section, text-only contributor links, and update status layout. Use the newly built app path to avoid accidentally testing an installed older copy.

### Logging and Operation Safety

- Route logs through `AppLogger.shared`. Serialize an event together with its detail fields; file-write failure must fall back to console output without terminating the app.
- Keep diagnostic subprocess time/output limits and redact usernames and storage paths in both text and JSON exports. `LogMenuState` refreshes menu size information when menus open; settings use observable defaults/bindings.
- Acquire a shared operation token before starting a file operation and release it on all completion/error paths. Block conflicting actions and page/language changes while busy.
- Recheck running apps at execution time through `AppRunningState`; do not rely only on a previously scanned `AppItem.isRunning` value.
- Reject stale asynchronous scan results and process deferred directory-change refreshes after an operation completes.
- Preserve both real copies when local/external data paths conflict. Relative links and symlinked parents must not redirect cleanup to unrelated data.

### Key Data Models

- `AppItem` (in `Models/AppModels.swift`): represents an app with name, path, status, flags (isSystemApp, isRunning, isAppStoreApp, isIOSApp, isResigned), containerKind, and size info.
- `DataDirItem` (in `Models/DataDirItem.swift`): represents a data directory with type (applicationSupport, containers, caches, dotFolder, etc.), priority, and link status.
- `CustomDirConfig` / `CustomDirPair` (in `Models/CustomDirModels.swift`): represents a user-selected folder migration and its local/external row state.
- `AppContainerKind`: `.standaloneApp`, `.singleAppContainer`, `.appSuiteFolder`

### UI Structure

- `Appports.swift`: `@main` entry, handles `WelcomeView` → `ContentView` flow, menu bar commands (language, logging)
- `ContentView`: main window with top-level tab switcher (Apps / Data Dirs / Directory Migration). Apps tab is an `HSplitView` — local apps left, external apps right
- `DataDirsView`: built-in data directory tab with Tool Dirs and App Data sub-tabs
- `CustomDirsView`: directory migration tab for arbitrary user folders, with local and external panes
- `AboutView`: standalone window opened through the app menu, not a sheet on `ContentView`

### Localization System

- Strings live in `AppPorts/Localizable.xcstrings` (22 languages)
- `LanguageManager` singleton with `.localized` extension on `String` for imperative code
- SwiftUI `Text("key")` literals are acceptable for `LocalizedStringKey` APIs
- AppKit/imperative strings must use `.localized` explicitly
- Language catalog in `AppLanguageCatalog` (in `Models/AppLanguageOption.swift`) — the single source of truth for supported languages
- `LocalizationAuditTests` validates translation coverage, placeholder consistency, absence of empty keys, absence of stale string catalog entries, and active `.localized` / `NSLocalizedString` references
- Hidden SwiftUI controls must still use meaningful localized labels; empty labels can create an empty string catalog key
- When adding new user-facing fields, status values, settings, alerts, errors, or labels, ask the maintainer whether to complete translations for all supported languages in the same change. If not, document the intended fallback/follow-up clearly.

### Global Singletons

- `AppLogger.shared` — structured logging with rotation, diagnostics export
- `LanguageManager.shared` — locale management, injected via `.environment(\.locale, ...)`
- `UpdateChecker.shared` — checks GitHub Releases and the official update feed
- `AppOperationState.shared` — cross-tab/window operation tokens and busy state

### Real-time Monitoring

`FolderMonitor` uses `DispatchSource` (kqueue) to watch `/Applications`, the external drive, and custom local app scan dirs, triggering automatic re-scans on filesystem changes.

### Key Architectural Patterns

- **Actor isolation**: all file operations are actor-isolated for thread safety
- **MVVM-ish**: views directly call service/utility methods; no formal ViewModel layer (except `ContributorsViewModel` in AboutView)
- **@AppStorage**: persistent settings (allowAppStoreMigration, allowIOSAppMigration, autoResignEnabled, LogEnabled, MaxLogSizeBytes)
- **UserDefaults**: external drive path, language selection, log configuration, custom local app scan paths (`customLocalScanPaths`), custom directory migration configs (`customDirConfigs`)
- **Progress callbacks**: `FileCopier.ProgressHandler` is `@Sendable (Progress) async -> Void` for real-time UI updates from actor contexts
- **Managed link metadata**: `.appports-link-metadata.plist` sidecar files for authoritative link tracking
- **Real-path signing for linked apps**: signing operations (resign, backup, restore) use `CodeSigner.resolveAppURL(at:)` and fail if the real target is unavailable. Never fall back to signing the local stub shell.
- **Stub Portal version sync**: when `FolderMonitor` or manual refresh detects an external app version change, `AppMigrationService.refreshStubPortal` updates the local stub portal's Info.plist, icon, and ad-hoc signature, then calls `lsregister -f` to refresh macOS Launch Services cache.
- **Structured error logging**: `AppLogger.shared.logError` accepts `errorCode` (e.g., `BACKUP-SIGNATURE-FAILED`, `RESIGN-FAILED`, `DATA-RESIGN-FAILED`) and `relatedURLs` for machine-parseable error tracking. Data directory operations include `appContextFields()` context (app_name, app_status, app_bundle_id, app_real_path, app_is_resigned).
- **Diagnostic export**: ZIP with redacted logs, operation summaries, system metadata
- **Zero external dependencies**: pure Apple frameworks only (SwiftUI, AppKit, Foundation, Combine)

## CI Configuration

- **PR smoke check** (`build.yml`): compilation-only build in Release mode. **Blocking.**
- **Tests (Advisory)** (`build.yml`): builds the Debug test bundle once, then runs the entire `AppPortsTests` target except `LocalizationAuditTests`. Localization runs separately using the same test bundle. Both results are advisory (non-blocking), including test-build failures.
- **Post-merge** (`post-merge-validation.yml`): full regression tests are mandatory; localization remains advisory. A successful Release build is checked for a valid app bundle and ZIP before uploading `AppPorts-Unsigned`. Runs on push to `main`/`develop`.
- **Shared commands**: `.github/scripts/run-xcode-check.sh` defines the build and test invocations for both workflows. Test execution uses `test-without-building` after `prepare-tests`; keep the two steps on the same runner and DerivedData directory.
- **Diagnostics**: step summaries distinguish passed, failed, cancelled, and not-run checks. Advisory jobs can be green after a test failure, so read their summary. Logs and `.xcresult` bundles are uploaded for five days.
- **Run policy**: a newer commit cancels older checks for the same PR. Post-merge validation is retained for merged commits. Workflows use read-only repository permissions and can also be started manually.
- Run the full suite on a disposable macOS runner. Some integration tests register temporary app bundles with Launch Services. Do not set `APPPORTS_TEST_EXTERNAL_ROOT` or `APPPORTS_RENDER_UI_OUTPUT` in CI, or run the test process with `sudo`.

## Branch Convention

- `main` — stable releases
- `develop` — integration branch; feature branches target `develop`
- Commit style: `feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`, `test: ...`

## Pull Request Workflow

When creating a Pull Request:

1. Ensure the branch is up-to-date with `develop`
2. Fill in all required fields in the PR template
3. Run `xcodebuild clean build` (Release) — this is mandatory
4. If the PR touches a tested module, run the corresponding test suite
5. For UI changes, attach screenshots

## Issue Workflow

When reporting a bug or proposing a feature:

1. Search existing Issues first to avoid duplicates
2. For bugs, attach a diagnostic package (Menu → 日志 → 导出诊断包)
3. For core feature proposals (migration strategy, data directory, code signing), detailed technical discussion is required before implementation

## Development Rules

- **Vibe Coding is accepted**, but code quality and correctness are the contributor's responsibility
- **Cross-validate AI-generated code** with multiple models when possible
- **Discuss large changes first**: major code churn, broad logic changes, migration strategy changes, data directory migration changes, and code signing changes should be discussed in GitHub Issues before implementation: https://github.com/wzh4869/AppPorts/issues
- **Never hardcode UI strings** — use i18n via `Localizable.xcstrings`
- **Never use `print`** — use `AppLogger.shared` for all logging
- **Always handle rollback** — migration operations must include rollback mechanisms on failure
