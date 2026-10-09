---
icon: "route"
description: "Learn how AppPorts chooses an app migration method."
layout:
  width: "default"
  outline:
    visible: true
---

# Migration Strategies

## App Container Classification <a href="#app-container-classification" id="app-container-classification"></a>

AppPorts classifies apps before migration to determine migration granularity:

| Classification | Definition | Example |
|----------------|------------|---------|
| `standaloneApp` | Single `.app` package in the top-level directory | Safari, Finder |
| `singleAppContainer` | Directory containing only 1 `.app` package | Some third-party app install directories |
| `appSuiteFolder` | Directory containing 2 or more `.app` packages | Microsoft Office, Adobe Creative Cloud |

Classification results affect migration strategy selection — `singleAppContainer` and `appSuiteFolder` migrate the entire directory as a unit, rather than processing individual `.app` files within.

## Three Migration Strategies <a href="#three-migration-strategies" id="three-migration-strategies"></a>

AppPorts defines three local entry (Portal) strategies for keeping apps launchable locally after migration:

### Whole App Symlink <a href="#whole-app-symlink" id="whole-app-symlink"></a>

Creates the entire `.app` directory (or directory) as a symbolic link pointing to external storage.

```text
/Applications/SomeApp.app → /Volumes/External/SomeApp.app
```

**Use Cases:**

- App container classification is `singleAppContainer` or `appSuiteFolder` (directory operation)
- Non-standard apps with path extensions other than `.app`

**Characteristics:** Finder displays arrow shortcut markers on icons.

### Deep Contents Wrapper (Contents Directory Migration) <a href="#deep-contents-wrapper-contents-directory-migration" id="deep-contents-wrapper-contents-directory-migration"></a>

Creates a real `.app` directory locally, with only the `Contents/` subdirectory symbolically linked to external storage.

```text
/Applications/SomeApp.app/
└── Contents → /Volumes/External/SomeApp.app/Contents  (symlink)
```

**Current Status:** Deprecated. New migrations no longer use this strategy; it is only recognized and handled when restoring apps migrated with older versions.

**Deprecation Reason:** Self-updaters follow the `Contents/` symbolic link and directly operate on external storage files, potentially corrupting the application.

### Stub Portal <a href="#stub-portal" id="stub-portal"></a>

Creates a minimal `.app` shell locally, calling `open` to launch the real app on external storage via a launch script.

```text
/Applications/SomeApp.app/
├── Contents/
│   ├── MacOS/launcher                    # native binary launcher (or bash script)
│   ├── Resources/real_app_path.txt       # external real app path
│   ├── Resources/AppIcon.icns            # icon copied from real app
│   ├── Info.plist              # simplified config file
│   └── PkgInfo                 # standard identifier file
```

**Use Cases:** All apps with `.app` extension (default strategy).

**Characteristics:** No symbolic links locally; Finder does not display arrow markers; auto-updaters cannot penetrate through.

#### macOS Stub Portal <a href="#macos-stub-portal" id="macos-stub-portal"></a>

For native macOS apps:

1. Create native binary launcher and write external app path to `real_app_path.txt`
2. Copy `PkgInfo` and icon files from the external app
3. Generate simplified `Info.plist` from the external app's `Info.plist`:
   - Set `CFBundleExecutable` to `launcher`
   - Set `LSUIElement` to `true` (not shown in Dock)
   - Remove Sparkle/Electron related config keys
   - Append `.appports.stub` suffix to Bundle ID
4. Execute Ad-hoc code signing

#### iOS Stub Portal <a href="#ios-stub-portal" id="ios-stub-portal"></a>

For iOS apps (iOS apps running on Mac), differences from macOS version:

- Icons extracted from `.app` packages in `Wrapper/` or `WrappedBundle/` directories
- Uses `sips` to scale PNG to 256×256 and convert to `.icns` format
- `Info.plist` generated from `iTunesMetadata.plist` (iOS apps don't include standard `Info.plist`)
- No code signing; only cleans extended attributes (`xattr -cr`)

## Strategy Selection Decision Tree <a href="#strategy-selection-decision-tree" id="strategy-selection-decision-tree"></a>

```mermaid
flowchart TD
    A[Start migration] --> B{Is it a directory operation?}
    B -->|Yes: singleAppContainer or appSuiteFolder| C[Whole App Symlink]
    B -->|No| D{Does path extension end with .app?}
    D -->|No| C
    D -->|Yes| E{Is it an iOS app?}
    E -->|Yes| F[iOS Stub Portal]
    E -->|No| G[macOS Stub Portal]
```

{% hint style="success" %}
**About Deep Contents Wrapper**

This strategy is no longer selected for new migrations in the current version. The `preferredPortalKind()` method returns `stubPortal` for all `.app` apps. Deep Contents Wrapper is only recognized as a legacy scheme when restoring historically migrated apps.
{% endhint %}

## Destination Conflicts and Replacement <a href="#destination-conflicts-and-replacement" id="destination-conflicts-and-replacement"></a>

When the external destination already contains a same-name item, AppPorts checks whether it can be safely replaced:

| Case | Behavior |
|------|----------|
| Current app is "Pending Move Out" | Clean the old external copy and replace it with the newer local app |
| Target is an AppPorts Stub Portal | Clean it and continue migration |
| Target is an old Deep Contents Wrapper or whole-app symlink entry | Treat it as a legacy AppPorts entry and clean it |
| Target is an unrelated real app or directory | Stop migration and report a conflict |

Legacy hybrid entries may keep symbolic links only at `Contents/Info.plist`, `Contents/MacOS`, `Contents/Resources`, or `Contents/Frameworks`. Current versions recognize those old structures for safe cleanup and restore, but do not delete real apps that cannot be identified as AppPorts-managed entries.
