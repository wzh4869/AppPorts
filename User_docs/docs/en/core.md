# Move applications

Application migration moves the app itself. Messages, projects, models and caches may remain on the Mac and need separate [data migration](/docs/datamigrae/operation).

## Before moving {#prepare}

Connect external storage, select an external application library under Destination Storage in the sidebar, and check free space under Mac Storage / Destination Storage. If the destination is an SMB network share or a non-APFS drive, you can create or open an [APFS app library image](/docs/storage-guide#app-library-image) from the Destination Storage menu to preserve full app metadata. Save your work, quit the app completely, and make sure AppPorts is running from Applications; back up important content first. System apps and protected locations are not suitable for direct moves. Follow the restrictions AppPorts shows.

## Move to an external drive {#move}

1. Select Apps in the sidebar, then select the app under Local Apps. Hold Command to select several apps.
2. Choose Move to External and check the destination. If the app includes a self-updater that requires confirmation, choose Unlocked Migration (default) or Locked Migration.
3. If a same-named destination or version choice appears, compare both sides. Do not delete an uncertain copy as though it were junk.
4. Wait for copying, verification and creation of the local entry. Download quarantine markers on macOS 27 do not abort migration; whether an app may open for the first time is still governed by macOS security checks.
5. Launch the app from Finder or the Dock and test everyday actions such as opening files.

The external library contains the real app; a [launch entry](/docs/glossary#local-portal) remains locally. Verification or cleanup may still be running near the end of the progress display. Wait for the final result.

If the app is outside the default scan locations, use + beside Local Apps to add a scan directory, such as an installation folder managed by another tool.

Use Task Center in the sidebar to inspect tasks, or Run in Background from task details and check again later. Pause and cancel requests need safe processing. Closing details does not cancel a task, and quitting AppPorts does not keep an active migration running in the background. See [Task Center](/docs/datamigrae/operation#task-center).

If a destination capability warning appears before migration, read [what the destination cannot store](/docs/storage-capabilities) before continuing. Permission to continue does not guarantee app compatibility.

## Updates after migration {#updates}

Update behavior differs by app. Apps confirmed to update cleanly as ordinary apps (such as NetEase Music and WorkBuddy) migrate without a lock prompt and show Linked when unlocked; other apps with detected self-updaters offer Unlocked Migration (highlighted by default) and Locked Migration before moving or relinking.

| Situation | Suggested action |
| --- | --- |
| In-app update fails under Unlocked Migration | Keep Application update guardian enabled under Settings → Background agents: when an eligible ShipIt update fails, the guardian verifies the cached new build and attempts installation, reporting results in Task Center. Failed tasks offer Roll Back Update to restore a verified previous build, or you can move the app back locally to update. |
| Locked Migration prevents an in-app update | Quit the app, move it back locally through AppPorts to update, then move it out again. Switching to Unlocked Migration or moving back locally also clears protection locks from the app's associated updater caches. |
| The updater installs the new version locally | Refresh the list. When Pending Move Out appears, verify the version and move out the new local app. |
| App Store manages the external installation (macOS 15.1+) | Use App Store external-install settings where supported; AppPorts can migrate App Store apps of any size, including apps under 1 GB. |
| App Store app on an older system | Check whether migration is enabled in settings. An update may require moving the new local version out again. |

On macOS 15.1 and later, App Store settings offer “Download and install large apps to a separate disk” on the same external drive. The App Store itself applies that setting only to newly downloaded apps larger than 1 GB and manages their updates; **AppPorts is not limited by the 1 GB threshold and can migrate App Store apps of any size, including apps under 1 GB**, into that drive's `Applications` folder. If you choose Don’t remind me again on the main-window prompt, you can still inspect the status and open App Store Settings at any time in [Settings and permissions](/docs/settings#app-store).

Application update guardian currently covers only explicitly failed ShipIt updates whose complete cached bundle passes signature verification; it does not guarantee compatibility with every updater framework or every ShipIt variant. See [update protection and guardian](/docs/migration-strategy/portal#updates).

## Move back or repair an entry {#restore-links}

- Move the real app onto the internal drive: use Move Back to Local.
- App still exists externally but has no local entry: use Link Back to Local.
- Remove only the local entry: click the `…` (More Actions) button or open the context menu on the row in Local Apps and choose Delete Local Entry.

See [Restore, reconnect and unlink](/docs/restore) for the distinctions and steps. If an app will not open, check the drive and [status messages](/docs/badges), then follow [troubleshooting](/docs/faq#launch).

## Lists, size caches and duplicate search results {#search-cache}

The All / Linked / Unlinked filter at the top of Apps filters the list without restoring or deleting apps; hidden selections are excluded from batch actions when switching filters. Local and external lists can each be sorted by name or size. App and tool-directory sizes can show a cache timestamp. If disk contents have changed or sizes look stale, click Refresh Cache at the bottom of the sidebar to recalculate; old cached sizes are not exact current usage.

If Spotlight shows both a local launcher and the external app, open the external-app indexing exclusion panel, inspect its report, then process unfinished items. Eligible standalone apps move into the external `AppPorts.noindex` app library while local entries remain usable. This changes the real app's location rather than merely hiding a search result. Suite folders, App Store apps and iOS apps are not handled automatically; conflicts and failures are listed separately. The entire disk is not excluded, and external documents and photos remain searchable. System indexing updates may take time.
