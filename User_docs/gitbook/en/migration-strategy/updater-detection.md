---
icon: "arrows-rotate"
description: "Understand detection and protection for self-updating apps."
layout:
  width: "default"
  outline:
    visible: true
---

# Self-Updater Detection

## Electron App Detection <a href="#electron-app-detection" id="electron-app-detection"></a>

AppPorts identifies Electron apps through the following three detection conditions (checked in order of priority, short-circuit evaluation):

| # | Detection Item | Path / Pattern |
|---|----------------|----------------|
| 1 | Electron Framework | `Contents/Frameworks/Electron Framework.framework` directory exists |
| 2 | Electron Helper variants | Entries containing `Electron Helper` in name exist under `Contents/Frameworks/` |
| 3 | Info.plist identifier keys | `ElectronDefaultApp` or `electron` key exists in `Contents/Info.plist` |

### Electron Self-Update Detection <a href="#electron-self-update-detection" id="electron-self-update-detection"></a>

Additionally checks for the existence of `Contents/Resources/app-update.yml` file (configuration file for `electron-updater`). If present, the Electron app is marked as having self-update capability.

## Sparkle App Detection <a href="#sparkle-app-detection" id="sparkle-app-detection"></a>

AppPorts identifies Sparkle apps through the following three detection conditions:

| # | Detection Item | Path / Pattern |
|---|----------------|----------------|
| 1 | Sparkle framework | `Contents/Frameworks/Sparkle.framework` or `Contents/Frameworks/Squirrel.framework` exists |
| 2 | Updater binary files | Files matching `shipit`, `autoupdate`, `updater`, `update` exist under `Contents/MacOS/` or `Contents/Frameworks/` |
| 3 | Info.plist Sparkle keys | Any of the following keys exist in `Contents/Info.plist`: `SUFeedURL`, `SUPublicDSAKeyFile`, `SUPublicEDKey`, `SUScheduledCheckInterval`, `SUAllowsAutomaticUpdates` |

{% hint style="warning" %}
**⚠️ Special Handling for Electron Apps**

When an app has been identified as an Electron app, detection condition #2 (updater binary files) is skipped to avoid false positives from `electron-updater`'s `updater` binary being detected as Sparkle.
{% endhint %}

## Hybrid Electron + Sparkle Apps <a href="#hybrid-electron-sparkle-apps" id="hybrid-electron-sparkle-apps"></a>

Some apps contain both Electron framework and Sparkle updater. AppPorts detects both flags independently, allowing `isElectron` and `isSparkle` to both be `true`.

### Detection Logic <a href="#detection-logic" id="detection-logic"></a>

```text
isElectron = satisfies any of the three Electron detection conditions
isSparkle  = satisfies any of the three Sparkle detection conditions (Electron apps skip condition #2)
```

The two flags are independent and can both be true simultaneously.

### Post-Migration Behavior <a href="#post-migration-behavior" id="post-migration-behavior"></a>

| Attribute | Determination Condition |
|-----------|------------------------|
| `hasSelfUpdater` | `isSparkle` or (`isElectron` and `app-update.yml` exists) or custom updater exists |
| `needsLock` | `isSparkle` or (`isElectron` and `app-update.yml` exists) |

When `needsLock` is `true`, AppPorts executes `chflags -R uchg` (setting immutable flag) on the external storage app after migration completes, preventing self-updaters from deleting or modifying the external copy.

## Custom Updater Detection <a href="#custom-updater-detection" id="custom-updater-detection"></a>

For native self-updating apps that are neither Sparkle nor Electron (e.g., Chrome, Edge, Parallels), AppPorts identifies them through the following patterns:

| Detection Path | Matching Pattern | Typical Apps |
|----------------|-----------------|-------------|
| `Contents/Library/LaunchServices/` | Filename contains `update` | Chrome, Edge, Thunderbird |
| `Contents/MacOS/` | Binary filename contains `update` or `upgrade` (excluding `electron`) | Parallels, Thunderbird |
| `Contents/SharedSupport/` | Filename contains `update` | WPS Office |
| `Contents/Info.plist` | `KSProductID` key exists | Google Keystone (Chrome) |

## Legacy Strategy Identification <a href="#legacy-strategy-identification" id="legacy-strategy-identification"></a>

When restoring or unlinking, AppPorts needs to identify legacy entries created by older versions:

| Local Structure Characteristic | Identified As |
|-------------------------------|---------------|
| Root path is a symbolic link | `wholeAppSymlink` |
| `Contents/` is a symbolic link | `deepContentsWrapper` |
| `Contents/Info.plist` is a symbolic link | `wholeAppSymlink` (legacy Sparkle hybrid scheme) |
| `Contents/Frameworks/` is a symbolic link | `wholeAppSymlink` (legacy Electron hybrid scheme) |
| `Contents/MacOS/launcher` exists | `stubPortal` |
| None of the above match | Not managed by AppPorts |
