# Questions and troubleshooting

Save your work and note the state and error AppPorts displays. For missing data or interrupted migration, preserve the original drive and existing copies before following the relevant checks.

## Why are permissions still missing after an upgrade when the switches are on? {#permissions-after-upgrade}

If **App Management** or **Full Disk Access** is already on after an upgrade but AppPorts still reports it missing, follow the reauthorization steps in [Readiness and system permissions](/docs/settings#permissions). If the old entry still does not work, clear its legacy record in **Readiness**.

## App will not open or quits immediately {#launch}

Check that the original external drive (or app library image) is online and the local entry is not an Orphaned Link. For Signature replaced, or a problem that began after upgrading to macOS 27, follow [upgrades and repair](/docs/macos-27). Otherwise check whether the original app supports the OS and retain error details. Not every launch failure is caused by signing.

## App opens but existing data is missing {#missing-data}

Quit the app to avoid writing into a newly created empty directory. In AppPorts, check for Mounted or a working link, then check the original app's Removable Volumes permission. Files existing externally does not establish that the app is connected to them. If both locations contain new data, preserve both, report the path types and states, and do not overwrite either.

## External drive not connected or Orphaned Link {#offline}

Reconnect the original drive, check Finder or Disk Utility, unlock it if needed, and refresh AppPorts. If the volume is online but shows Awaiting Mount, choose Mount (if you previously clicked Unmount on an individual data volume, automatic mounting stays paused until you explicitly choose Mount or Resume automatic mounting). While an external drive is offline, managed local directories appear as read-only, traversable empty folders to prevent accidental local writes; seeing an empty folder does not mean data was deleted or restored locally. If the original drive and destination are confirmed and the issue persists, [export diagnostics](/docs/faq#feedback).

## An app library image does not remount automatically or fails verification {#image-library}

First confirm that the SMB share or external drive holding the image is mounted in Finder (reconnect in Finder if macOS has no saved SMB credentials, and unlock encrypted volumes), and check that AppPorts is located in Applications with Disk maintenance agent enabled under Settings → Background agents.

If you previously chose Unmount Image in the sidebar, automatic recovery stays paused across NAS reconnections and AppPorts restarts; choose Mount Image Again from the Destination Storage menu to resume. If the image volume was renamed in Finder, its mount path changes and identity verification fails; rename the volume back to its original name and remount it. See [using an APFS app library image](/docs/storage-guide#app-library-image).

## Mount migration checks fail {#mount}

Check permissions, connectivity, format and encryption under Readiness in Settings. Installation location and operation-specific space are checked when starting migration. Container mount migration currently requires APFS; do not apply that requirement to all other content. Choose another destination or keep data local. See [storage preparation](/docs/storage-guide#apfs).

## After migrating, an app says the data directory is not mine {#owners}

Such messages come from the app's own background service — for example clash-verge's system service refusing to start the kernel (error 1012). The usual cause is not lost permissions but a target disk that does not record file ownership: exFAT and FAT32 have no ownership field, and HFS+ mounted with ownership ignored writes new files as a placeholder user. Your account sees itself; the administrator service sees that placeholder, so the two disagree.

The message often suggests `sudo chown`, but on such volumes the system silently drops the change — it looks successful while changing nothing. What works: restore this data locally, or move it to an APFS disk (APFS keeps the real owner); for HFS+ you can untick “Ignore ownership on this volume” in Finder's Show Info and migrate again. exFAT has no such switch. See [Does the external drive remember file owners?](/docs/storage-guide#owners).

## Destination exists, a copy is retained, or cleanup is incomplete {#conflict}

Check Current data and Retained old copy paths separately in the recovery panel. Target Conflict needs an ownership check; Copy Retained or failed cleanup may mean the main operation succeeded but cleanup remains (root-owned old copies offer Authorize Old-Copy Cleanup). Follow the retry or retain options. Do not repeat migration, manually delete recovery copies or overwrite same-named directories. See [restoration and reconnection](/docs/restore) for the differences between repairing an entry, Force Unlink and moving data back.

## Should I restart an interrupted migration? {#interrupted}

Keep the original storage connected and inspect AppPorts' recovery instructions. Interruption can occur during copying, switching or cleanup, with different valid copies remaining at each stage. Preserve the temporary directories and backups identified by the app. If uncertain, record the last step and error rather than choosing a copy to delete yourself.

## What is unsuitable for migration? {#compatibility}

System apps, protected container structures, the entire home folder and overlapping managed directories have additional restrictions. Virtual machines, databases and downloading game libraries may have background writers; stop their use completely first. Detecting a directory does not establish that its app supports arbitrary external storage. Prefer an app's own storage-location setting when appropriate.

## Why are some container directories protected? {#protected}

Some directories maintain system structure, such as the container root and specific temporary directories. Changing them can prevent launch even when copying and mounting succeed. Respect protection messages; see [container structure experiments](/docs/blog/data-migration-boundaries#starting-point) for the evidence.

## How do I update a moved app? {#updates}

Look for Locked Migration or Unlocked Migration. Under Unlocked Migration, apps can attempt in-app updates, and enabling Application update guardian under Settings → Background agents allows AppPorts to assist with eligible failed ShipIt updates and offer Roll Back Update if recovery fails. Under Locked Migration, move the app back locally, update it and move it out again if updating is blocked. App Store-managed external installations have their own process. Follow [application updates](/docs/core#updates), without deleting the external copy just to get an update through.

## Why does Disk Utility show extra AppPorts volumes? {#volumes}

They may be dedicated mount-migration data volumes. They may not remain visible in Finder's sidebar, but hold real data. To undo migration, use Restore in AppPorts rather than erasing or deleting the volumes in Disk Utility.

## Can I delete AppPorts Backups? {#signature-backups}

This folder holds official app originals saved before manual re-signing, not message or document backups. If you no longer need an original and no operation is pending, you may delete that package in Finder. The installed app and personal data remain, but restoring official status may then need an official installer. AppPorts also removes originals proven redundant; see [retention and cleanup](/docs/settings#signature-backup-cleanup).

If recovery cannot find an original, connect its drive and verify that the folder is still in place. New originals are external even when the app remains internal. Without suitable external storage, re-signing a new official original stops before changing the installed app.

## Before removing AppPorts {#uninstall}

Restore container data it still manages and confirm cleanup; if you no longer want background services, you can also turn off Disk maintenance agent and Application update guardian in Settings first. Removing the program alone does not return data locally and may leave automatic reconnection without its executable. Check moved apps and ordinary data using the [restoration guide](/docs/restore) too, and establish where they are stored.

## Does AppPorts upload my files automatically? {#privacy}

Migration runs locally. Logs and diagnostic packages are also stored locally first. Version checks, user-initiated in-app update downloads, and contributor or sponsor list loading use the network, so the app is not entirely offline. See the [privacy policy](/docs/privacy) for information and recipients.

## Report a problem {#feedback}

In [GitHub Issues](https://github.com/wzh4869/AppPorts/issues), describe AppPorts and macOS versions, drive format, the operation, the complete error message and reproducibility. Use Export Diagnostic Package under Log Settings or Logs → Export Diagnostic Package in the menu bar to obtain records. Check for private paths or content before sharing. Packages are not uploaded automatically; do not publish messages, account details or unrelated files.

## Automatic mounting stops after ejection or unmounting {#eject}

An explicit Eject External Disk request from AppPorts pauses automatic mounting for the entire physical disk. Even if Finder's ejection is cancelled, **unplug and reconnect the device** to resume. By contrast, Unmount Image or clicking Unmount on an individual data volume persistently keeps automatic mounting paused across drive reconnections until you explicitly choose Mount Image Again or Mount / Resume automatic mounting. If volumes remain mounted during physical disk ejection, quit apps using them and choose Retry Eject instead of pulling the cable. See [disk ejection](/docs/storage-guide#eject).

## A task is paused, cancelling or needs attention {#tasks}

Pause waits for a safe checkpoint; cancellation waits for safe cleanup. Keep the drive connected. Run in Background only closes details; return through Task Center in the sidebar. For a task needing attention, open Resolve Issues (or Roll Back Update for a failed background update task), keep the copies identified and follow [recovery](/docs/restore#recovery). Historical tasks do not automatically repeat migration after restart, and completed background cleanup does not prove the original migration succeeded.

## Launching says app data is being migrated {#launch-protection}

An updated native launcher asks you to wait while associated data is migrating, being restored or paused during copying. Check the task in AppPorts and wait for completion. Protection cannot stop other routes such as opening the real app directly. Do not bypass the warning; see [launch protection](/docs/datamigrae/operation#launch-protection) for its scope.
