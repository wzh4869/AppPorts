# Changelog

## v1.9.0 (In Development) <a href="#v1-9-0-in-development" id="v1-9-0-in-development"></a>

### Important Changes <a href="#important-changes" id="important-changes"></a>

- **Container data uses mount migration by default**: directories under `Containers` and `Group Containers` move to dedicated volumes on an unencrypted APFS external drive, mounted at their original paths without changing app signatures. Allow Removable Volumes access on first launch. See [Mount Migration](datamigrae/mount-migration.md).
- **Sandboxed apps are not re-signed by default**: the old method requires manually enabling classic mode and confirming the risks for the current real app. Re-signed apps may fail to open on macOS 27. See [Upgrading to macOS 27](macos-27.md).
- **Fixed "Restore Original Signature"**: a complete original app is backed up before re-signing, and a verified working copy safely replaces the current app. Original signatures and entitlements can be restored without the developer's private key. Legacy records can use an official original copy of the same version. Updated apps and damaged backups are not forcibly overwritten.
- **Signature detection and repair guidance**: original signing records and the real app’s current signature identify replacements; unsuccessful checks have a separate pending state. Use the inline repair action to restore old symlinked container data, then recover the original app or reinstall an official copy as appropriate. Complete backups do not require moving the app locally first. Ordinary scans retain recovery materials.
- **Classic data migration mode**: off by default, with risk confirmation and a [full documentation link](settings.md#classic-data-migration-mode) in Settings. Container data can remain on the Mac when a drive is not APFS. Mount migration that preserves the original signature is recommended on macOS 27.
- **Automatic re-signing at login is disabled on macOS 27 and later**: AppPorts turns off the setting and stops and removes old login tasks, with retry available in Settings if cleanup is incomplete. **Update and open AppPorts once before upgrading macOS** to add version protection to installed scripts; downloading alone does not update them. Earlier systems retain existing settings.
- "Normalize", "Relink", and "Link Details" are disabled for container directories outside classic mode, preventing symbolic links from being recreated.

### Improvements <a href="#improvements" id="improvements"></a>

- **First-run guidance and readiness checks**: checks Full Disk Access, App Management permission, and storage, with direct System Settings links. Completion is remembered, and checks remain available in Settings.
- **Directory tree and inline actions**: grouped parent and child directories, larger controls, and type symbols inside folder icons. Common actions are directly accessible. Fixed forced centering, inconsistent parent and child sizes, and button alignment.
- **Backup updates and cleanup retries**: verified official updates create a new recovery point and archive old signing backups. Incomplete cleanup after restoration is tracked separately; retries do not copy data again, and cleanup records can be removed while retaining copies.
- **Dialogs and other fixes**: long explanations scroll, Cancel and Esc behave consistently, and action dialogs close correctly. Log limits display `100 MB` correctly. Restoration from a local link resolves the external app instead of reporting a false local-file conflict.
- **Documentation and project support**: updated migration, repair, and navigation in eight languages, with sponsor, license, and privacy links in the About window and menus.
- **“Migrate” checks requirements before offering the next step**: checks cover storage connection, format, encryption, and free space. Choosing or changing storage continues the check for the selected directory. Guidance explains space, permissions, and drive requirements, or offers keeping the current setup, choosing another location, and reading preparation instructions.
- **Data volumes are hidden in Finder**: newly created volumes do not automatically mount under `/Volumes`, and mounting uses `nobrowse`. Volumes mounted by earlier versions are hidden in place at the next launch or drive connection, without unmounting.
- **Encrypted APFS drives are not yet supported for mount migration**: new volumes do not inherit the original volume's password. AppPorts stops and explains instead of silently creating an unencrypted volume.
- **Free-space checks before migration and restoration**: insufficient external or local space stops the operation before volume creation or copying.
- **Safer restoration**: only the empty mount point is deleted after unmounting, without recursive deletion. Staging directories now use hidden names. If the final step cannot complete, the external volume and record remain intact and AppPorts reports the local copy's location.
- **Only operate on AppPorts volumes**: mount, unmount, and restore verify the volume identity at the mount point. Operations do not start without the lock shared with the login agent. An unreadable migration record file is never treated as an empty record and overwritten.
- **Automatic login-agent path updates**: each launch checks the agent's executable path and updates it after AppPorts is moved or upgraded. Running directly from a DMG or Downloads through a temporary App Translocation path blocks new mount migrations and asks you to move AppPorts to Applications first.
- Mount migration retries with the system administrator password prompt on systems requiring elevated privileges, such as macOS 12.
- Container volumes are automatically reconnected when possible at login and drive connection, with background operations coordinated with AppPorts. Timing depends on drive availability and system authorization and is not guaranteed to precede every login app. Older systems requiring administrator authorization need AppPorts to be opened to complete mounting.
- **The login agent is no longer deferred behind login items**: it uses `KeepAlive` to declare that it needs to run, restarting only after failure, and removes `ProcessType: Background`. The user domain stays in on-demand-only mode for a period after login; the old definition could be delayed about 20 seconds while login apps started in 3 seconds.
- **Volumes mounted automatically by macOS are remounted correctly**: when a volume is already mounted under `/Volumes`, `diskutil mount -mountPoint` can ignore the requested path, print `mounted`, and return 0. This occurred on 2026-09-21 and 09-23: the command succeeded while the intended mount point remained empty, so WeChat read an empty directory. AppPorts now verifies the actual destination after every mount and, if necessary, unmounts from `/Volumes` and retries, up to 3 rounds.
- **Removed the most expensive boot-time `diskutil` query**: macOS first mounts volumes under `/Volumes/<卷名>`. The agent now identifies them using `statfs` and a volume-root marker in microseconds, avoiding a `diskutil info` query measured at 9 seconds. On a real Mac, a round from locating the volume to completing its mount now needs only `unmount` and `mount`, taking about 1 second.
- **The login agent keeps waiting for slow drives**: it watches `/Volumes` within the process and retries after real changes. Tests measured about 1 second from volume appearance to completed mounting. With no events, it checks every 20 seconds as a fallback, over a total 180-second window. It does not hold the shared lock while waiting.
- **Idle login-agent runs no longer flood logs**: launchd matches `WatchPaths` using FSEvents path prefixes, so any write on an external drive can wake the agent even when no action is needed. An idle run now writes only 3 lines; detailed per-record logs appear only for actual mounting, offline volumes, or failures.
- **Halved `diskutil` calls in the mounting path**: queries per volume drop from 4 to 2 by checking availability and the current mount location in one `diskutil info` call. Each query can take around a second during a busy boot, saving several seconds.
- **Spotlight no longer indexes data volumes**: volume creation writes `.metadata_never_index` at the root and removes any `.Spotlight-V100` already created, which totaled 110 MB across two tested WeChat volumes. Older migrated volumes receive the marker on their next mount. It stays with the volume and is not copied back to the local directory during restoration.
- Fixed generic terms such as `CN`, `mac`, and `desktop` matching unrelated containers, including WPS data appearing for Trae CN and QQ Music data appearing for Termius.
- Fixed missing subdirectory scans when container paths appear in `/private/var` form.

## v1.8.0 <a href="#v1-8-0" id="v1-8-0"></a>

### New Features <a href="#new-features" id="new-features"></a>

- Added custom local scan directories: the "Mac Local Apps" header now has a "+" button to add extra local app scan directories. Useful for tools like JetBrains Toolbox and Steam that install apps outside `/Applications`. Added directories are persisted and automatically monitored for changes (#48).
- Added Stub Portal version sync: when an external app is updated via the App Store, the local Stub Portal's version info is now automatically synced and the macOS Launch Services cache is refreshed. The "Open With" menu no longer shows stale version numbers (#50).
- Added tool directory detection for Gradle (`~/.gradle`), Android development data (`~/.android`), and Flutter/Dart Pub cache (`~/.pub-cache`) (#49).
- Added Directory Migration: add arbitrary user folders in the "Directory Migration" tab, migrate large projects, models, asset libraries, or tool caches to external storage, and relink or restore them later (#54).
- Added protected-app migration warning: before migrating App Store apps or root-owned apps, AppPorts warns that automatic deletion or replacement may fail due to permissions and suggests manually moving the app in Finder before creating a link (#55).

### Improvements <a href="#improvements-1" id="improvements-1"></a>

- Faster app scanning: Info.plist reads per app reduced from 7 to 1 (via in-memory cache), significantly improving scan speed.
- Scan timeout protection: the `codesign` subprocess now has a 10-second timeout, preventing large app signature checks from blocking the entire scan indefinitely.
- Directory size calculation safety cap: a 500,000 file count limit has been added to recursive size calculations, preventing runaway enumeration on Electron and other large app bundles.
- Scan trace logging: per-app TRACE logging added to the scan loop, making it easier to identify which app is slow or stuck during scanning.
- More precise data directory matching: fixed bundle ID suffix extraction to filter generic TLD words like `app`, `com`, `org`. Previously, bundle IDs like `cn.trae.app` would trigger scanning of 720+ unrelated system containers.
- More complete tool-directory relink detection: when a local tool directory is missing but a managed directory still exists at the canonical external-storage location, AppPorts shows it as "Needs Relinking"; switching external storage refreshes tool-directory state automatically.
- Improved localization and accessibility: app, data-directory, and custom-directory statuses, sort/filter labels, settings toggles, and status badges now follow the selected language more consistently and expose clearer accessibility labels.
- App sizes now use a session-level cache, reducing cases where sizes return to "Calculating" or disappear after a refresh (#55).
- Safer data-directory rollback: before creating the link, AppPorts renames the local source to a hidden safety backup. If link creation or backup cleanup fails, it keeps the local backup and external copy where possible to avoid losing both sides (#54).

### Fixes <a href="#fixes" id="fixes"></a>

- Fixed Trae and similar apps scanning extremely slowly — the generic suffix `app` from the bundle ID caused `~/Library/Containers/` to scan hundreds of unrelated directories.
- Fixed local Stub Portal version info not updating after external apps are updated via the App Store, causing the "Open With" menu to show stale versions.
- Fixed the refresh button not triggering Stub Portal version sync.
- Fixed data-directory relinking or normalization potentially treating an external regular file as a directory; regular files are now rejected and left untouched.
- Fixed multi-line dialog bodies falling back to Chinese in some languages, completed Russian UI translations, and localized the Stub Portal "external storage not connected" system dialog based on the system language (#55).

## v1.7.0 <a href="#v1-7-0" id="v1-7-0"></a>

### New Features <a href="#new-features-1" id="new-features-1"></a>

- Added "Pending Move Out" status: when the real local app is newer than the app with the same name on external storage, AppPorts marks it as pending move out, indicating that the local newer version can be safely migrated out to replace the external older copy.
- Added re-sign confirmation for data migration: before migrating data inside an app container, AppPorts can ask whether to automatically apply Ad-hoc re-signing to the related app after migration, reducing the risk of unrecognized data, warnings, or launch failures after container data migration (#44).

### UI Improvements <a href="#ui-improvements" id="ui-improvements"></a>

- Rearranged the top toolbar: app/data-directory tab buttons now use a more compact icon + text style.
- Optimized the data-directory action bar: the Tool Directories / App Data switch, post-migration re-sign toggle, restore original signature button, and refresh button now live in the top toolbar.
- Added a "Pending Move Out" app status badge for apps whose local version is newer than the external old copy.
- Localized the data migration re-sign confirmation dialog, including title, body text, and buttons.

### Improvements <a href="#improvements-2" id="improvements-2"></a>

- Strengthened app migration safety: when the external destination already exists, AppPorts only auto-cleans it if it is identified as an AppPorts-managed old portal, a stale migration remnant, or the app is in "Pending Move Out" state.
- Strengthened data-directory recovery checks: automatic recovery no longer relies on similar directory size and now requires full AppPorts metadata matching.
- Made app data scanning more stable: results from older scan tasks no longer overwrite the data-directory list for the currently selected app.
- Improved escaping for admin commands and AppleScript: paths containing quotes, backslashes, spaces, or Chinese characters are handled more safely.
- Improved localization: fixed help content, prompts, and data migration confirmation text that could remain in Chinese or be incomplete after switching languages, and completed translations for all supported languages (#43).

### Fixes <a href="#fixes-1" id="fixes-1"></a>

- Fixed data directory migration incorrectly treating a real external directory as a recoverable target.
- Fixed app migration potentially deleting a real external app with the same name by mistake.
- Fixed unstable detection and cleanup of old external AppPorts portals or stale migration remnants.
- Fixed malformed AppleScript or admin commands when paths contain special characters.
- Fixed background migration or post-migration re-signing reading the app after the selected app had changed.
- Fixed the "Pending Move Out" status badge not appearing in the app list.

## v1.6.2 <a href="#v1-6-2" id="v1-6-2"></a>

- New: Auto re-sign at login. Automatically re-signs migrated apps with expired signatures each time the user logs in, no manual action needed. Enabled by default, can be turned off in Settings
- Improvement: Stub Portal now uses a native Mach-O binary launcher instead of the legacy bash script, fixing the issue where double-clicking associated documents in Finder could not open the external app (#42)
- Improvement: About page layout optimized with scrollable content area, fixing content being cut off when the window is too small
- Fix: Native Stub Portal being incorrectly identified as a regular local app
- Fix: Unable to properly clean up native Stub Portal when moving apps back to local storage
- Fix: App shell being treated as a complete app during link-back-to-local operations
- Fix: AutoResignInstaller silently succeeding when installation fails

## v1.6.1 <a href="#v1-6-1" id="v1-6-1"></a>

- Fixed: Auto-re-signing after data directory migration now correctly signs the real external app instead of the local stub shell
- Fixed: Re-signing and signature restore operations now correctly resolve the real path for linked apps
- Fixed: "Re-signed" status detection for linked apps now correctly identifies the signing status of the real external app
- Improved: Log output includes structured error codes and related path information

## v1.6.0 <a href="#v1-6-0" id="v1-6-0"></a>

- Migrated apps no longer show arrow badges
- Auto-updating apps are no longer broken by updates after migration
- Added app signature management feature to fix "Damaged" prompts after migration
- External storage disconnection now shows red "Orphaned Link" warnings
- macOS 15.1+ users can install App Store apps directly to external drives
- Data directory migration is safer: prevents accidental system directory migration, auto-recovers from interruption
- Scanning and size calculation are faster; list no longer jumps
- File copying to external storage is more stable; no more errors on interruption
- App status badges redesigned with richer information and clickable details
- App list no longer loses selection after refresh; data directories support tree view
- UI refinements: search, sort, group cards, icon loading, etc.
- Added Martian language option
- Automated test updates

## v1.5.5 <a href="#v1-5-5" id="v1-5-5"></a>

- Added macOS 15.1+ App Store app external installation support
- Added auto re-signing feature (auto-executed after data directory migration)
- Added `LocalizationAuditTests` localization audit tests
- Improved Stub Portal Info.plist generation logic
- Fixed Launchpad icon loss issue for some apps after migration

## v1.4.0 <a href="#v1-4-0" id="v1-4-0"></a>

- Added data directory tree view
- Added tool directory detection (30+ development tools)
- Added diagnostic package export feature
- Improved self-update detection (Chrome, Edge, and other custom updaters)
- Fixed auto-recovery mechanism after migration interruption

## v1.3.0 <a href="#v1-3-0" id="v1-3-0"></a>

- Added data directory migration feature
- Added code signature management (backup/restore original signatures)
- Added Sparkle and Electron app auto-detection
- Improved locked migration protection (`chflags uchg`)
- Fixed badge display issues in Finder

## v1.2.0 <a href="#v1-2-0" id="v1-2-0"></a>

- Added Stub Portal migration strategy (replacing Deep Contents Wrapper)
- Added iOS app migration support (Mac version iOS apps)
- Improved batch migration performance
- Fixed issue where some apps could not launch after restore

## v1.1.0 <a href="#v1-1-0" id="v1-1-0"></a>

- Added multi-language support (20+ languages)
- Added app suite directory migration (e.g., Microsoft Office)
- Improved external storage offline detection
- Fixed symbolic link penetration issue with Deep Contents Wrapper strategy

## v1.0.0 <a href="#v1-0-0" id="v1-0-0"></a>

- First official release
- Supported app migration to external storage (Deep Contents Wrapper / Whole App Symlink)
- Supported app restore and link management
- Supported FolderMonitor real-time file system monitoring
