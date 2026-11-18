# Changelog

These entries describe changes at the time of each release. **Historical features may have been retired and should not be treated as current instructions.** Current guides describe the latest interface and behavior. Older behavior, versions, and alternatives remain in the [historical feature archive](/docs/archive/overview).

## v2.3.0 {#v2-3-0}

- Add the Large files & videos only (`msg/file + msg/video`) mode for WeChat accounts: mutually exclusive with Whole migration and Split migration (`msg + business`), allowing databases and `msg/attach` chat thumbnails to stay local while cold files and videos move externally, measured in a single filesystem pass.
- Make Unlocked Migration the default for self-updating apps and add the optional Application update guardian background agent to handle failed ShipIt updates, sync status into Task Center, and offer verified Roll Back Update recovery.
- Verify macOS 15.1+ Mac App Store external-install settings read-only instead of checking for an empty folder marker, add persistent Don’t remind me again guidance, and clarify in Settings how the App Store's >1 GB auto-download rule differs from AppPorts migrating App Store apps of any size.
- Harden runtime status, task locking and disk operations: lock active-task row and batch actions in place, fix whole-disk ejection volume resolution across multi-partition disks, detect running migrated external apps accurately, prune hidden filter selections, cache writable storage capability probes, deduplicate per-scan volume status queries, and eliminate redundant snapshot cleanup hashing.

[View v2.3.0](https://github.com/wzh4869/AppPorts/releases/tag/2.3.0) · Guides: [WeChat split migration](/docs/datamigrae/operation#wechat) · [update protection and guardian](/docs/migration-strategy/portal#updates) · [App Store settings](/docs/settings#app-store) · [Task Center](/docs/datamigrae/operation#task-center)

## v2.2.0 {#v2-2-0}

- Add APFS app library disk images (`.sparsebundle`): create, open and remount an image inside a mounted SMB share or external drive to store migrated apps while preserving signatures and filesystem attributes, verified by backing storage identity and the image's APFS volume UUID.
- Add background recovery and launch preparation for app library images: login, volume events and scheduled background checks reattach the selected image, and refreshed local entries (format 8) run a silent windowless step to reattach the image and its data volumes before launching an app.
- Support explicit Unmount Image from the sidebar with persistent pause of automatic recovery across NAS reconnections and AppPorts restarts until manually remounted.
- Redesign the resizable sidebar navigation and capacity overview: consolidate Apps, Tool Directories, App Data, Directory Migration, Task Center and Destination Storage, and remove the misleading internal “space saved” estimate.
- Add a floating drag-and-drop icon guide for Full Disk Access, and verify that AppPorts runs from Applications before starting new migrations, image operations or permission guides.
- Improve background mount-agent registration and attribution in System Settings, unify all managed offline entries (including split-migrated WeChat media paths) under read-only traversable protection, fix migration failures on macOS 27 caused by download quarantine markers, and optimize directory-size scanning and content-verification scheduling.

[View v2.2.0](https://github.com/wzh4869/AppPorts/releases/tag/2.2.0) · Guides: [app library images](/docs/storage-guide#app-library-image) · [permissions and readiness](/docs/settings#permissions)

## v2.1.0 {#v2-1-0}

- Redesign the application migration view, adding All / Linked / Unlinked filtering, independent name and size sorting on local and external lists, and a unified refresh control.
- Add in-app updates for AppPorts with China-mirror and GitHub download options, SHA-256 and signature/architecture verification, and Install and Restart.
- Add Force Unlink inside Link Details so disconnected links can be removed locally and replaced with an empty directory while preserving external originals.
- Persist automatic-remount pauses after manually clicking Unmount on an individual data volume until Mount or Resume automatic mounting is explicitly chosen; allow read-only traversal on offline placeholder directories while continuing to block writes.
- Reuse complete App Data scan results within the current session, distinguish missing Full Disk Access from missing data, display Current data separately from Retained old copy in recovery panels, and support administrator-authorized cleanup for root-owned retained copies.

[View v2.1.0](https://github.com/wzh4869/AppPorts/releases/tag/2.1.0) · Guides: [in-app updates](/docs/settings#updates) · [Force Unlink](/docs/restore#unlink) · [recovery](/docs/restore#recovery)

## v2.0.0 {#v2-0-0}

- Support whole-account or media-only split migration for WeChat, keeping databases and configuration local in split mode. Restore fully before changing modes.
- Support encrypted APFS destinations with an independent password for new data volumes and optional local Keychain storage. Unlock manually without saved credentials.
- Add external-app indexing exclusion and size-cache refresh controls to reduce duplicate search entries and check cache timestamps.
- Add Task Center for apps, app data, tools and custom directories, with background execution inside AppPorts, pause, continue, cancel and history controls. Tasks with conflicting resources wait in the queue.
- Show estimated overall progress across stages and separate preparation, scan, copy, verification, switch and cleanup steps for the current directory. Multi-directory totals no longer stand in for the current stage.
- Distinguish retry, deciding later and keeping old copies. App recovery also offers explicit confirmation for ending an incomplete task or moving back without content verification.
- Add whole-disk ejection: pause automatic mounting before asking Finder to eject, and resume after the device is reconnected.
- Updated native macOS launchers ask users to wait during app-data migration or restoration. Other routes, including directly launching the real app, are outside this protection.
- Destination capability warnings explain app file attributes that cannot be preserved and link to the relevant help page. Ordinary app migration and container mount migration have distinct storage requirements.
- Adjust concurrent reads for data scans and small-file copying while retaining content verification, pre-switch checks and safe cleanup. No fixed speedup is promised across storage devices.
- Continue to separate migration from manual signing, store official originals externally and disable automatic login re-signing on all systems. Complete multilingual prompts for the new interface.

[View v2.0.0](https://github.com/wzh4869/AppPorts/releases/tag/2.0.0) · Guides: [Task Center](/docs/datamigrae/operation#task-center), [recovery](/docs/restore#recovery), [disk ejection](/docs/storage-guide#eject) and [launch protection](/docs/datamigrae/operation#launch-protection).

## v1.9.1 (development history) {#v1-9-1}

The following preserves the earlier **1.9.1 build 31** development record. These behaviors continue in 2.0.0:

- App data hides locked, non-migratable structures by default. “Show locked directory structure” reveals their reasons. Status summaries support filtering. Personal-folder shortcuts are identified separately, excluded from app-data sizes, and unavailable for migration.
- Progress distinguishes preparation, copying, verification, and finalization. Reaching 100% copying still requires waiting for the whole operation to finish. Extended inactivity displays the last activity.
- Data migration and manual re-signing are separate; migration no longer automatically signs apps.
- Complete official originals saved before manual signing go automatically to the visible external `AppPorts Backups` folder, with Chinese and English instructions. No new location selection is needed. Without a suitable external drive, signing stops before changing the live app. Internal apps still require temporary internal space.
- Useful older internal originals move externally when conditions permit. Redundant originals and invalid old records are cleaned up according to verification results. Material with recovery value or unclear provenance remains; an offline drive does not mean its backup is lost.
- Signature menus follow status: confirmed re-signed apps retain “Restore Original Signature” and hide duplicate re-signing. Eligible signing actions return after official state is restored.
- Automatic login re-signing is disabled on every macOS version, and its permanent settings card is removed. AppPorts handles the old login task when opened, showing a retry only if cleanup fails.
- Stronger copy validation and container-structure protection recheck data before switching or cleanup.
- Verified originals remain available for recovery. “Signature replaced” and “Signature check pending” are distinguished, with a repair panel for older migrations.
- Fixed re-signing continuing after official-original signature verification failed. Failure or timeout now stops it. Interrupted-signing recovery avoids committing withdrawn operations in the background or re-signing an already completed operation.

Related: [migrate data](/docs/datamigrae/operation) · [signature originals](/docs/settings#signature-backups) · [upgrade and repair](/docs/macos-27) · [automatic-signing archive](/docs/archive/data-signing)

## v1.9.0 {#v1-9-0}

- Container data defaults to mount migration: eligible data enters a dedicated unencrypted APFS volume attached at its original directory, preserving the app signature.
- Sandboxed app re-signing is restricted by default. Classic mode requires risk confirmation; older-signature checks, complete backups, and repair entries are provided.
- Added readiness and pre-migration checks explaining permissions, installation location, external format, encryption, and free space.
- Improved remounting after login and drive connection, including actual mount-location checks. Waiting still depends on the drive and system authorization.
- Improved handling of restoration, backup, and cleanup failures, plus the data tree, inline actions, dialogs, localization, and project-support entries.
- Login re-signing was disabled on macOS 27 at that time. 1.9.1 development builds extend this to every system version.

[View v1.9.0](https://github.com/wzh4869/AppPorts/releases/tag/v1.9.0). Its transitional post-migration signing and earlier login tasks are now documented in the [archive](/docs/archive/data-signing#versions).

## v1.8.0 {#v1-8-0}

### New features {#v1-8-0-features}

- Custom local scan directories: a “+” beside “Local Apps” adds app locations outside `/Applications`, such as JetBrains Toolbox or Steam installations. Paths persist and file changes are monitored (#48).
- Automatic Stub Portal version synchronization: after an external app updates through the App Store, local portal metadata and the Launch Services cache refresh so “Open With” no longer shows an old version (#50).
- Tool-directory support for Gradle (`~/.gradle`), Android development data (`~/.android`), and Flutter/Dart Pub cache (`~/.pub-cache`) (#49).
- Custom folder migration for projects, models, asset libraries, and tool caches, with relink and restore (#54).
- Protected-app warnings before moving App Store or root-owned apps. They explain possible automatic deletion/replacement permission failures and suggest moving through Finder before creating a link (#55).

### Improvements {#v1-8-0-improvements}

- In-memory caching reduces each app's Info.plist reads from seven to one, improving scan speed.
- A 10-second timeout for codesign subprocesses prevents large signature checks from stalling scans.
- Recursive size calculation stops at 500,000 files to bound traversal of very large bundles such as Electron apps.
- Per-app TRACE logging helps identify scan stalls.
- More precise bundle-ID suffix matching filters generic terms such as app, com, and org, avoiding unrelated system-container scans.
- Tool directories show “Awaiting Relink” when the local path is missing but a managed external directory remains at the standard location. Changing external storage refreshes their state.
- App, data, and custom-folder states, sort/filter labels, switches, and badges follow the selected language more consistently, with clearer accessibility labels.
- Session-level app-size caching reduces repeated “Calculating” states and disappearing sizes after refresh (#55).
- Safer data rollback renames the local source to a hidden backup before linking. Link creation or cleanup failures try to preserve both that backup and the external copy (#54).

### Fixes {#v1-8-0-fixes}

- Fixed extremely slow scans for apps such as Trae, caused by the generic bundle-ID suffix `app` matching many unrelated `~/Library/Containers/` directories.
- Fixed stale Stub Portal versions and “Open With” entries after external App Store updates.
- Fixed refresh not triggering portal-version synchronization.
- Fixed relink/normalization treating an external ordinary file as a directory. Such files are now rejected and preserved.
- Fixed multiline dialogs falling back to Chinese in some languages and completed Russian UI translations. The portal's disconnected-storage dialog also follows the system language (#55).

## v1.7.0 {#v1-7-0}

### New features {#v1-7-0-features}

- “Pending Move Out” identifies a real local app newer than the same-named external app, offering migration of the newer version to replace the older copy.
- Container-data migration confirmation offered optional automatic ad-hoc signing afterward, intended to reduce recognition, storage, and startup issues (#44). **This historical automatic-signing flow is now retired; see the [archive](/docs/archive/data-signing).**

### Interface improvements {#v1-7-0-ui}

- More compact icon-and-text toolbar switches for apps and data directories.
- Tool/app-data switching, post-migration signing, original-signature restoration, and refresh were grouped in the top toolbar. **The automatic-signing portion is historical and retired; see the [archive](/docs/archive/data-signing).**
- Added the “Pending Move Out” badge to distinguish newer local versions from older external copies.
- Localized migration-signing confirmation titles, text, and buttons. **This automatic-signing flow is retired; see the [archive](/docs/archive/data-signing).**

### Improvements {#v1-7-0-improvements}

- Existing external targets are automatically cleaned only when recognized as managed old entries, migration remnants, or when the app is “Pending Move Out.”
- Data recovery no longer relies on similar directory sizes. Automatic relink/recovery requires a full AppPorts metadata match.
- Old scan results no longer replace the selected app's data after rapid app switching.
- Safer administrator-command and AppleScript escaping for quotes, backslashes, spaces, and Chinese characters in Finder deletion and permission repair.
- Completed supported-language translations for help, dialogs, and migration confirmations that previously remained Chinese or incomplete after switching language (#43).

### Fixes {#v1-7-0-fixes}

- Fixed mistaking real external directories for recoverable migration targets.
- Fixed potential deletion of a same-named real external app during migration.
- Fixed unreliable recognition and cleanup of old external portals and migration remnants.
- Fixed malformed AppleScript or administrator commands with special-character paths.
- Fixed background migration or post-migration signing reading the newly selected app after a selection change. **Automatic signing is now retired; see the [archive](/docs/archive/data-signing).**
- Fixed the missing “Pending Move Out” badge in app lists.

## v1.6.2 {#v1-6-2}

- Added automatic ad-hoc re-signing of migrated apps with invalid signatures at each login, enabled by default with a settings switch. **This historical feature is now retired; see the [archive](/docs/archive/data-signing).**
- Replaced the old bash Stub Portal launcher with a native Mach-O executable to fix opening associated documents by double-clicking in Finder (#42).
- Made About content scrollable to prevent clipping in small windows.
- Fixed native portals being mistaken for ordinary local apps.
- Fixed cleanup of native portals when moving back locally.
- Fixed treating a launcher as a complete app when linking back locally.
- Fixed AutoResignInstaller silently reporting success after installation failure.

## v1.6.1 {#v1-6-1}

- Post-migration signing now targeted the real external app rather than the local Stub Portal. **This automatic-signing flow is now retired; see the [archive](/docs/archive/data-signing).**
- Signing and signature restoration correctly resolved linked apps' real paths.
- Re-signed status detection checked the real external app's signature.
- Added structured error codes and associated paths to logs.

## v1.6.0 {#v1-6-0}

- Migrated apps no longer displayed shortcut-arrow badges.
- Self-updating apps no longer broke external copies during updates.
- Added signature management to address post-migration “damaged” warnings.
- Disconnected storage produced a red “Orphaned Link” state.
- macOS 15.1+ users could install App Store apps directly to external storage.
- Safer data migration protected system directories and supported recovery after interruption.
- Faster scanning and size calculation reduced list movement.
- More stable external copying handled interruptions better.
- Redesigned clickable app-state badges with more information.
- Refresh retained selection; data directories gained a tree view.
- Refined search, sorting, grouped cards, and icon loading.
- Added a Martian-language option.
- Updated automated tests.

## v1.5.5 {#v1-5-5}

- Support for macOS 12 and later.
- Added the Martian-language option.

## v1.5.0 {#v1-5-0}

- External App Store installation support on macOS 15.1+.
- Automatic signing after data migration. **Now retired; see the [archive](/docs/archive/data-signing).**
- Added `LocalizationAuditTests`.
- Improved Stub Portal Info.plist generation.
- Fixed missing Launchpad icons after migrating some apps.

## v1.4.0 {#v1-4-0}

- Data-directory tree view.
- Recognition of more than 30 development-tool directories.
- Diagnostic-package export.
- Improved custom updater detection, including Chrome and Edge.
- Fixed automatic recovery after migration interruption.

## v1.3.0 {#v1-3-0}

- Data-directory migration.
- Code-signature management with original-signature backup/restore.
- Automatic Sparkle and Electron detection.
- Improved locked migration (`chflags uchg`).
- Fixed Finder badge display.

## v1.2.0 {#v1-2-0}

- Stub Portal replaced Deep Contents Wrapper as a migration strategy.
- Support for iOS apps running on Mac.
- Improved batch-migration performance.
- Fixed some apps failing to launch after restoration.

## v1.1.0 {#v1-1-0}

- More than 20 interface languages.
- App-suite folder migration, such as Microsoft Office.
- Improved offline external-storage detection.
- Fixed symlink traversal in Deep Contents Wrapper.

## v1.0.0 {#v1-0-0}

- First official release.
- External app migration through Deep Contents Wrapper / Whole App Symlink.
- App restoration and link management.
- Live filesystem monitoring through FolderMonitor.
