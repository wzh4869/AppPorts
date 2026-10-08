# Status Badges

AppPorts displays the current status of apps and data directories using capsule-shaped colored badges. Some badges are clickable for detailed information.

## App Status Badges <a href="#app-status-badges" id="app-status-badges"></a>

### Link Status <a href="#link-status" id="link-status"></a>

| Badge | Icon | Color | Meaning |
|-------|------|-------|---------|
| Linked | `link` | Green | App migrated to external storage with local entry |
| Locked Migration | `lock.fill` | Green | Linked and locked with `uchg`, preventing self-updates from damaging external app |
| Unlocked Migration | `lock.open` | Orange | Linked but not locked; in-app updates may delete external app |
| Partial Link | `link.badge.plus` | Yellow | Partial app components linked (e.g., some `.app` files in a directory) |
| Orphan Link | `link.badge.exclamationmark` | Red | External storage app lost but local entry still exists |
| Unlinked | `externaldrive.badge.xmark` | Orange | App on external storage but not linked back locally |
| External | `externaldrive` | Orange | App on external storage with no local entry |
| Pending Move Out | `arrow.up.right.circle` | Cyan | The real local app is newer than the old external copy and can be moved out to replace it |
| Local | `macmini` | Secondary color | Regular local app, not migrated; shown when no other tags present |

{% hint style="success" %}
**How Pending Move Out Is Detected**

AppPorts matches local and external apps by Bundle ID first, then falls back to a normalized app name when needed. The badge only appears when both versions can be compared and the local version is higher. Missing or non-comparable versions, or same-name apps with different Bundle IDs, stay in the normal local state to avoid accidental replacement.
{% endhint %}

### Framework Labels <a href="#framework-labels" id="framework-labels"></a>

| Badge | Icon | Color | Meaning | Click Action |
|-------|------|-------|---------|-------------|
| Sparkle | `arrow.triangle.2.circlepath` | Cyan | Uses Sparkle framework for auto-updates | After migrating to external storage, in-app updates may cause external app loss; locked migration recommended |
| Electron | `atom` | Indigo | Based on Electron framework with auto-update support | After migrating to external storage, in-app updates may cause external app loss; locked migration recommended |

### Type Labels <a href="#type-labels" id="type-labels"></a>

| Badge | Icon | Color | Meaning |
|-------|------|-------|---------|
| Running | `play.fill` | Purple | App currently running |
| System | `lock.fill` | Gray | macOS system application |
| Non-native | `iphone` | Pink | iOS/iPadOS app (running via Apple Silicon) |
| Store | `applelogo` | Blue | Mac App Store application |

### Special Labels <a href="#special-labels" id="special-labels"></a>

| Badge | Icon | Color | Meaning |
|-------|------|-------|---------|
| Resigned | `seal.fill` | Cyan | The app currently has an Ad-hoc signature, and AppPorts has a signature backup for it |
| Signature replaced | `exclamationmark.shield.fill` | Red | AppPorts replaced the developer signature with an Ad-hoc signature. The app may not open on macOS 27. Click for details, or right-click and choose "Show repair steps" to open the repair panel. See [Upgrading to macOS 27](macos-27.md) |

{% hint style="success" %}
**"Resigned" and "Signature replaced"**

Both mean the app currently has an Ad-hoc signature. The difference is **its original signature**. An app marked "Resigned" originally had no developer signature, or its original signature can no longer be confirmed; re-signing simply lets it open normally. An app marked "Signature replaced" originally had a developer signature that was replaced with Ad-hoc. This may prevent sandboxed apps from opening on macOS 27, so AppPorts highlights them in red and provides repair steps.
{% endhint %}

{% hint style="success" %}
**💡 Special Note on Store Label**

When an app meets the following conditions, the "Store" label becomes clickable and displays macOS 15.1+ native installation instructions:
- App is located in the `/Volumes/{drive}/Applications/` directory on external storage
- Natively managed by macOS; App Store can perform incremental updates directly in this directory
{% endhint %}

## Data Directory Status Badges <a href="#data-directory-status-badges" id="data-directory-status-badges"></a>

| Status | Color | Meaning |
|--------|-------|---------|
| Local | Secondary color | The directory is local and has not been migrated. A shield beside a container directory indicates that it uses mount migration |
| Linked | Green | Symbolic-link migration is complete; the local link points to the external drive |
| Mounted | Purple | Mount migration is complete; the external volume is mounted at the original directory |
| Awaiting mount | Orange | The volume is online but is not mounted; click "Mount" |
| Drive Not Connected | Red | The data volume cannot be found, usually because the external drive is disconnected. AppPorts reconnects it automatically when the drive is connected |
| Needs Normalization | Yellow | An AppPorts-managed link whose external path is not in the standard location; use "Normalize" |
| Awaiting Relink | Orange | The external data still exists but the local link is missing; use "Relink" |
| Existing Symlink | Blue | A symbolic link created outside AppPorts; you can choose to bring it under AppPorts management |

## App Status Combinations <a href="#app-status-combinations" id="app-status-combinations"></a>

An app may display multiple badges simultaneously:

```text
[已链接] [Sparkle] [运行中]
```
Meaning: App migrated to external storage, uses Sparkle auto-update framework, currently running.

```text
[外部] [商店] [非原生]
```
Meaning: iOS app (Mac version) on external storage, installed via App Store.

```text
[孤立链接]
```
Meaning: External storage app lost or removed, but local entry still retained. Manual unlinking required.

```text
[待迁出]
```
Meaning: A newer real app exists locally while the external storage still has an older copy. Re-run migration to move the local version out and replace the old external copy.
