---
icon: "table-list"
description: "Find the migration strategy for each app type."
layout:
  width: "default"
  outline:
    visible: true
---

# App Types & Strategies

| App Type | Container Classification | Migration Strategy | Lock Protection | Notes |
|----------|--------------------------|-------------------|-----------------|-------|
| Native macOS app (no self-update) | `standaloneApp` | macOS Stub Portal | No | e.g., Safari, Finder |
| Sparkle self-updating app | `standaloneApp` | macOS Stub Portal | **Yes** | e.g., some indie developer apps |
| Electron app (no `app-update.yml`) | `standaloneApp` | macOS Stub Portal | No | e.g., VS Code |
| Electron app (with `app-update.yml`) | `standaloneApp` | macOS Stub Portal | **Yes** | e.g., Slack, Discord |
| Electron + Sparkle hybrid app | `standaloneApp` | macOS Stub Portal | **Yes** | Both flags detected independently |
| Custom updater apps (Chrome, Edge) | `standaloneApp` | macOS Stub Portal | No | Identified via `LaunchServices`, `KSProductID`, etc. |
| iOS app (Mac version) | `standaloneApp` | iOS Stub Portal | No | Icons extracted from `WrappedBundle`; no signing |
| Mac App Store app | `standaloneApp` | macOS Stub Portal | No | SIP protection; cannot be re-signed |
| Single app container directory | `singleAppContainer` | Whole App Symlink | No | Directory with only 1 `.app`; whole symlink |
| App suite directory (e.g., Office) | `appSuiteFolder` | Whole App Symlink | Depends on internal apps | Directory with 2+ `.app`; whole symlink |
| Non-`.app` path | — | Whole App Symlink | — | Path with extension other than `.app` |

{% hint style="warning" %}
**⚠️ About Lock Protection**

When an app is marked as needing lock (`needsLock = true`), AppPorts executes `chflags -R uchg` on the external storage app after migration completes, setting the immutable flag. This prevents self-updaters from deleting or modifying the external copy, but also means the app cannot self-update. Users need to manually unlock in AppPorts before updating.
{% endhint %}

{% hint style="success" %}
**💡 Why Custom Updater Apps Are Not Locked**

Apps using custom updaters like Chrome and Edge are not locked. These apps' updaters typically download and install new versions to local internal storage. Due to macOS Stub Portal's link isolation characteristics, this does not damage app files on external storage.

When AppPorts detects that the app version on local internal storage is higher than on external storage, it automatically tags the app with "Pending Move Out," prompting the user to re-migrate to synchronize the latest version.
{% endhint %}
