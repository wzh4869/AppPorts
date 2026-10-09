---
icon: "circle-question"
layout:
  width: "default"
  outline:
    visible: true
---

# FAQ

## Installation and Permissions <a href="#installation-and-permissions" id="installation-and-permissions"></a>

### What Permissions Does AppPorts Need? <a href="#what-permissions-does-appports-need" id="what-permissions-does-appports-need"></a>

AppPorts needs **Full Disk Access** to read and modify `/Applications`. First launch guides you through granting it. You can also add AppPorts manually in System Settings → Privacy & Security → Full Disk Access.

### Which macOS Versions Are Supported? <a href="#which-macos-versions-are-supported" id="which-macos-versions-are-supported"></a>

AppPorts supports macOS 12.0 (Monterey) and later. macOS 15.1 (Sequoia) and later also support installing App Store apps on external storage and updating them there.

### Can I Use a NAS or Network Drive as External Storage? <a href="#can-i-use-a-nas-or-network-drive-as-external-storage" id="can-i-use-a-nas-or-network-drive-as-external-storage"></a>

AppPorts is primarily intended for local external storage, such as portable hard drives, external SSDs, and drive enclosures. NAS, SMB, rclone, and SFTP mounts can theoretically appear as file-system paths in macOS, but stability, permissions, latency, and reconnection depend on the mounting solution.

If you want to try a network drive, first test with an unimportant app or rebuildable data directory, and confirm that:

- The mount path is accessible before AppPorts starts.
- It can automatically remount at the same path after a disconnection.
- The file system supports the permissions, extended attributes, and symbolic links required by the app.
- You do not start with valuable or frequently written data such as WeChat, virtual machines, or game libraries.

## App Migration <a href="#app-migration" id="app-migration"></a>

### How Do I Scan Apps Outside /Applications? <a href="#how-do-i-scan-apps-outside-applications" id="how-do-i-scan-apps-outside-applications"></a>

Click "+" on the right of the "Mac Local Apps" heading and select an additional directory. This is useful for tools such as JetBrains Toolbox and Steam that install apps in custom locations. Added directories are saved, scanned automatically next time, and monitored for changes. The heading shows their count; open that menu to view or remove directories.

### What if an App Will Not Open After Migration? <a href="#what-if-an-app-will-not-open-after-migration" id="what-if-an-app-will-not-open-after-migration"></a>

1. Confirm that external storage is connected and accessible.
2. Check the app's badge. "Orphan Link" means the external app is missing and its local link must be removed manually.
3. If macOS reports that the app is "damaged", try reinstalling first. If that does not help, consider "Resign This App" in the right-click menu; sandboxed apps are refused.
4. If the problem remains, move the app back from the external library to restore local operation.
5. If opening does nothing or the icon briefly appears and disappears, see [Upgrading to macOS 27](macos-27.md).

### What if I See a "Damaged" Message? <a href="#what-if-i-see-a-damaged-message" id="what-if-i-see-a-damaged-message"></a>

This usually means macOS code signing detected a change to the app bundle structure.

1. Download and reinstall from the official website or App Store first. This resolves most cases.
2. If the message remains, right-click the app in AppPorts and choose "Resign This App". AppPorts backs up the original signature and applies an Ad-hoc signature.
3. Sandboxed apps are refused: re-signing may prevent them from opening on macOS 27, so these apps need reinstallation.

See [Re-signing and Crash Prevention](datamigrae/resign.md) for the mechanism.

### Will the App Crash if I Unplug External Storage? <a href="#will-the-app-crash-if-i-unplug-external-storage" id="will-the-app-crash-if-i-unplug-external-storage"></a>

The local Stub Portal tries to launch the external app using `open`. Without the drive, the app cannot start, but the local launcher itself does not crash. Reconnecting the drive restores normal use.

### Why Do Some Migrated Apps Still Show Shortcut Arrows? <a href="#why-do-some-migrated-apps-still-show-shortcut-arrows" id="why-do-some-migrated-apps-still-show-shortcut-arrows"></a>

This can happen with older AppPorts versions. The current version uses Stub Portal for ordinary `.app` bundles, so the local item looks like a normal app and generally has no shortcut arrow.

If an arrow remains, you are probably still using a whole-app symbolic link from an older version. Move the app back to this Mac, then migrate it again with the current version.

### Can Apps Update After Migration? <a href="#can-apps-update-after-migration" id="can-apps-update-after-migration"></a>

It depends on the app type:

| App Type | Automatic Updates | Details |
|----------|:-----------------:|---------|
| Native apps without a self-updater | ✓ | Update as before |
| Chrome / Edge with custom updaters | ✓ | Updates install locally; AppPorts marks the newer local version "Pending Move Out" |
| Sparkle / Electron apps | ✗ | Locking prevents in-app updates; move back with AppPorts before updating |
| App Store apps on macOS 15.1+ | ✓ | App Store updates them directly on the external drive |
| App Store apps on macOS <15.1 | ✗ | Manual migration is needed again |

### What Does "Pending Move Out" Mean? <a href="#what-does-pending-move-out-mean" id="what-does-pending-move-out-mean"></a>

A real local app exists and AppPorts considers it newer than the same app's external copy. This commonly happens when Chrome, Edge, or another custom updater installs the new version locally while the external drive keeps the old version.

Migrate the app again to replace the old external copy. AppPorts matches by Bundle ID first, then normalized app name. It does not show this badge if versions are missing or incomparable, or same-name apps have different Bundle IDs.

### Will an Existing External Destination Be Overwritten? <a href="#will-an-existing-external-destination-be-overwritten" id="will-an-existing-external-destination-be-overwritten"></a>

Not directly. AppPorts automatically cleans up an external destination and continues only when:

- The app is "Pending Move Out" and the destination is an older copy of the same app.
- The destination is an old Stub Portal, Deep Contents Wrapper, or whole-app symbolic-link entry created by AppPorts.
- The destination is a stale remnant of an AppPorts migration.

If a real app or directory cannot be confirmed to belong to the migration, AppPorts stops with a destination conflict to avoid deleting user data.

### How Do I Migrate App Store Apps to an External Drive? <a href="#how-do-i-migrate-app-store-apps-to-an-external-drive" id="how-do-i-migrate-app-store-apps-to-an-external-drive"></a>

**macOS 15.1+**: in App Store settings, enable "Download and install large apps to a separate disk" and choose the same external storage as the AppPorts external app library.

**macOS <15.1**: enable App Store app migration in AppPorts Settings. This requires manual migration, and you must migrate again after updates to replace the external copy.

### Why Am I Warned About a Protected App Before Migration? <a href="#why-am-i-warned-about-a-protected-app-before-migration" id="why-am-i-warned-about-a-protected-app-before-migration"></a>

App Store apps and root-owned apps are usually protected by macOS permissions. AppPorts may be unable to delete or replace their local copies directly. Move the app to external storage in Finder first; macOS asks for an administrator password. Then return to AppPorts and create a local link. You can still choose automatic migration, but it may fail for lack of permission.

### Why Are There Duplicate Open With Entries or Inconsistent Versions After an App Store Update? <a href="#why-are-there-duplicate-open-with-entries-or-inconsistent-versions-after-an-app-store-update" id="why-are-there-duplicate-open-with-entries-or-inconsistent-versions-after-an-app-store-update"></a>

Version 1.8.0 and later automatically synchronize the external app's version to the local Stub Portal, updating Open With. If versions still differ, click Refresh to trigger synchronization.

For v1.7.0 and earlier:

1. Refresh the local and external app lists in AppPorts.
2. If the local version is newer, migrate it again to replace the external copy.
3. If only the local entry is wrong, remove its link, then link the app back locally from the external library.

On macOS 15.1 and later, prefer native App Store external installation to reduce divergent versions.

### Double-Clicking a Document Opens the App but Not the File <a href="#double-clicking-a-document-opens-the-app-but-not-the-file" id="double-clicking-a-document-opens-the-app-but-not-the-file"></a>

Apps such as Office and WPS rely on file-association arguments. Older Stub Portals may launch the external app without correctly passing the selected file's path. Upgrade to v1.6.2 or later, then move the affected app back and migrate it again, or recreate its local link from the external library.

If the issue remains, export a diagnostic package and submit an Issue with the installation source, such as App Store, official `.pkg`, or DMG, and reproduction steps.

### Can I Migrate Suites Such as Adobe or Office? <a href="#can-i-migrate-suites-such-as-adobe-or-office" id="can-i-migrate-suites-such-as-adobe-or-office"></a>

You can try, but these often consist of several apps, shared components, background services, and licensing modules rather than one standalone `.app`. AppPorts tries to handle suites as directories; compatibility still depends on their structure.

Quit every app in the suite and confirm it is signed in or activated before migration. If licensing, file associations, or components fail afterward, move the suite back and consider migrating only its larger standalone apps or data directories.

### Migration Is Slow or Stuck. What Should I Do? <a href="#migration-is-slow-or-stuck-what-should-i-do" id="migration-is-slow-or-stuck-what-should-i-do"></a>

- Progress may pause for one or two seconds near 100% while AppPorts creates the local entry and performs final checks.
- Large apps such as Xcode and Adobe apps normally take longer.
- If progress stops for a long time, check the external connection.
- USB 2.0 is slow; use USB 3.0 or later, or Thunderbolt.

## Data Directory Migration <a href="#data-directory-migration" id="data-directory-migration"></a>

### Can Data Be Lost During Data Directory Migration? <a href="#can-data-be-lost-during-data-directory-migration" id="can-data-be-lost-during-data-directory-migration"></a>

Normally, no. AppPorts copies the data completely to external storage and confirms success before removing the original local directory and creating the symbolic link. If a step fails, it attempts automatic rollback.

If the external directory already exists, recovery continues only when `.appports-link-metadata.plist` fully matches the source path, destination path, and data directory type. A real directory without matching metadata is a conflict; similar size alone never permits takeover or overwriting.

### When Can Data Directory Migration Cause App Problems? <a href="#when-can-data-directory-migration-cause-app-problems" id="when-can-data-directory-migration-cause-app-problems"></a>

- The app uses file locks or SQLite WAL logs.
- Extended attributes may be lost or behave differently across symbolic links.
- Multiple apps from the same Team share a `Group Containers` directory.

Directories under `~/Library/Containers/` and `~/Library/Group Containers/` use mount migration, which requires APFS and approval of the first-launch permission prompt. See [Mount Migration](datamigrae/mount-migration.md).

### Can WeChat Chat History Be Stored on an External Drive? <a href="#can-wechat-chat-history-be-stored-on-an-external-drive" id="can-wechat-chat-history-be-stored-on-an-external-drive"></a>

Yes, with "Mount migration". Select WeChat in "App Data". The per-account `xwechat_files` subdirectories and `Application Support/com.tencent.xinWeChat` under the `Containers` group can use mount migration. The drive must be APFS. Allow the permission prompt the first time WeChat opens afterward.

**Do not** use the old migration-plus-re-signing workflow; it prevents WeChat from opening on macOS 27.

### My WeChat Chat History Is Missing After Migration <a href="#my-wechat-chat-history-is-missing-after-migration" id="my-wechat-chat-history-is-missing-after-migration"></a>

There are two cases:

- **Mount migration with 1.9.0**: check that the drive is connected, the directory is "Mounted", and you did not deny the permission prompt. See [Troubleshooting](troubleshooting.md#app-cannot-see-data-after-mount-migration).
- **Symbolic-link migration with an older version**: sandboxed WeChat cannot read outside its container through a link. This is a platform restriction. Restore the directory locally in AppPorts; if you agreed to re-sign, also reinstall WeChat from its website. See [Upgrading to macOS 27](macos-27.md#repair).

**Do not** try to repair this by re-signing; that makes it worse.

### Can I Migrate WeChat Data to an exFAT Drive? <a href="#can-i-migrate-wechat-data-to-an-exfat-drive" id="can-i-migrate-wechat-data-to-an-exfat-drive"></a>

No, mount migration requires APFS. **Leaving the drive unchanged is fine**: keep WeChat data on this Mac and migrate the app itself and other data normally. When you want to move container data later, another APFS drive is the simplest option. If the current disk has unallocated space, an APFS partition can be created when the partition layout permits. If exFAT fills the disk, neither macOS nor Windows built-in tools can shrink it directly; back up and repartition first. Free space inside exFAT is not unallocated disk space. We tested disk images as a workaround, but unplugging made the whole image unusable, so they are not offered. See [Why External Drives Must Use APFS](why-apfs.md#what-to-do). This restriction does not affect apps or ordinary data directories.

### Will Mount Migration Add Disk Icons in Finder? <a href="#will-mount-migration-add-disk-icons-in-finder" id="will-mount-migration-add-disk-icons-in-finder"></a>

No. AppPorts hides mounted data volumes from the Finder sidebar and desktop. They may briefly appear for a second or two after the drive connects, then disappear when remounted. Disk Utility still shows `AppPorts-…` volumes containing your migrated data. Do not erase or delete them. See [Mount Migration: Daily Use](datamigrae/mount-migration.md#daily-use).

### Why Is Mount Migration Unavailable on My Encrypted Drive? <a href="#why-is-mount-migration-unavailable-on-my-encrypted-drive" id="why-is-mount-migration-unavailable-on-my-encrypted-drive"></a>

A new data volume does not inherit the original volume's password. Migrating normally would move protected data to a volume without a password. AppPorts stops instead of silently reducing protection. See [Encrypted External Drives](why-apfs.md#encrypted-drives).

### What Should I Do Before Deleting AppPorts? <a href="#what-should-i-do-before-deleting-appports" id="what-should-i-do-before-deleting-appports"></a>

If you used mount migration, restore those directories in App Data first. Otherwise the data remains on the external volumes, but nothing remounts them after login and the app sees empty folders. Reinstall and open AppPorts once to recover.

### Is an App Failing After Upgrading to macOS 27 Because of Earlier Data Migration? <a href="#is-an-app-failing-after-upgrading-to-macos-27-because-of-earlier-data-migration" id="is-an-app-failing-after-upgrading-to-macos-27-because-of-earlier-data-migration"></a>

The data is intact; the signature is the issue. Agreeing to re-sign during container migration in an older version removed the app's sandbox identity. macOS 27 then refuses access to its own container. Restore the data and reinstall the app; see [Upgrading to macOS 27](macos-27.md).

### Should I Migrate Crossover, Parallels, Virtual Machines, or Game Libraries? <a href="#should-i-migrate-crossover-parallels-virtual-machines-or-game-libraries" id="should-i-migrate-crossover-parallels-virtual-machines-or-game-libraries"></a>

The app bundles are often not the largest part. Virtual disk images, containers, game libraries, and model caches usually consume more space. First check whether Data Directories or Tool Directories detects those large folders.

For virtual disks, databases, or frequently written files, ensure the external storage performs reliably and back up first. Network mounts are not recommended for such workloads.

### How Do I Restore a Migrated Data Directory? <a href="#how-do-i-restore-a-migrated-data-directory" id="how-do-i-restore-a-migrated-data-directory"></a>

Find the migrated directory and click "Restore". For symbolic links, AppPorts copies the data locally, then removes the link and external copy. For mount migration, it copies the volume's data locally before deleting the volume. Keep the external drive connected.

## Other <a href="#other" id="other"></a>

### Does AppPorts Collect My Data? <a href="#does-appports-collect-my-data" id="does-appports-collect-my-data"></a>

No. AppPorts runs offline and does not collect or upload user data. Logs remain locally in `~/Library/Application Support/AppPorts/`.

### How Do I Report a Problem? <a href="#how-do-i-report-a-problem" id="how-do-i-report-a-problem"></a>

Submit feedback on the project's [Issues](https://github.com/wzh4869/AppPorts/issues) page. Include a diagnostic package from the menu bar's log export action to help identify the problem faster.
