# Mount Migration: Move Container Data to an External Drive

{% hint style="success" %}
**The key point**

Data in `~/Library/Containers/` and `~/Library/Group Containers/`, including WeChat chat history, QQ Music caches, and App Store app data, cannot be moved using symbolic links. Starting with AppPorts 1.9.0, AppPorts creates a dedicated APFS data volume on the external drive, copies the data into it, and **mounts that volume at the original directory**. The app sees the same path, and its signature stays unchanged.

Three requirements: use an unencrypted APFS external drive, allow the permission prompt the first time you open the app, and connect the drive before opening the app.
{% endhint %}

## When to Use It <a href="#when-to-use-it" id="when-to-use-it"></a>

Select an app under "Data Directories" → "App Data". Directories in the `Containers` and `Group Containers` groups show "Mount migration" instead of "Migrate". Other groups, such as `Application Support` and caches, as well as tool directories and custom directories, continue to use symbolic links.

For why containers are different, and why the main executable's sandbox status is not decisive, see [Container Data, Sandboxing, and Signing Identity](container-identity.md).

## After Clicking "Mount migration" <a href="#preflight" id="preflight"></a>

AppPorts first checks external storage without making changes, then offers the next step based on the result:

| Check Result | What You See | What You Can Do |
|--------------|--------------|-----------------|
| Unencrypted APFS with enough space | An explanation of the local space you can free, the first-launch permission prompt, and keeping the drive connected | Click "Migrate Data" to begin |
| exFAT, NTFS, HFS+, or another format | A message identifying the external storage format | "Keep As Is", "Choose Another Location", or "View Preparation Guide" |
| Encrypted APFS | A message explaining that the external storage is encrypted | "Keep As Is" or select an unencrypted APFS location |
| Not enough space | Required and available space | Free some space and check again, or choose another location |
| No external storage selected or connected | A prompt to select or connect external storage | Select external storage and check again |

**If migration is unavailable, you do not need to change anything.** Apps, `Application Support`, caches, and tool directories can still be migrated to this drive. Leave container data on this Mac and use the app normally. When you want to migrate it later, follow [Prepare an APFS External Drive](../why-apfs.md#prepare-apfs).

{% hint style="info" %}
**Why encrypted APFS drives are not supported yet**

A new data volume does not inherit the original volume's password. Migrating normally would place chat history protected by FileVault on this Mac onto a volume with no password. AppPorts avoids silently reducing that protection until automatic unlocking and password management are ready. See [Encrypted External Drives](../why-apfs.md#encrypted-drives).
{% endhint %}

## Before Migration <a href="#before-migration" id="before-migration"></a>

- **Move AppPorts to the Applications folder and open it from there first.** The login agent needs a persistent app path. Running directly from Downloads or a DMG may use a temporary App Translocation path; AppPorts blocks new mount migrations from such paths and asks you to install it. Open AppPorts once after moving or updating it so it can update the agent's path. It does not reload the agent when the path is unchanged.
- **Quit the app completely.** AppPorts checks and refuses migration while the app is running.
- **Give AppPorts Full Disk Access.** Mounting a volume at a container path is controlled by the system and fails without permission.
- **Consider backups.** As with any data migration, back up important data first. After migration it lives on the external drive. Time Machine usually excludes external drives; if needed, check that this drive is included in the backup options under System Settings → General → Time Machine.

## What Happens During Migration <a href="#what-happens-during-migration" id="what-happens-during-migration"></a>

1. Create a volume in the external drive's APFS container without automatically mounting it under `/Volumes`. Its name resembles `AppPorts-<Bundle ID>-<目录名>-xxxxxx`. It shares the container's free space with other volumes; no size needs to be specified.
2. Temporarily mount it under `~/Library/Application Support/AppPorts/mounts/`, copy the directory contents with the AppPorts copier, write `.appports-mount-metadata.plist` at the volume root, and unmount it.
3. Rename the original directory to a safety backup on the same volume, create an empty directory at the original path, mount the new volume there, and verify its identity.
4. Save the mount record in `~/Library/Application Support/AppPorts/container-mounts.plist`, install the automatic remount agent, and finally remove the safety backup.

If external space is insufficient, AppPorts stops before creating a volume. If a failure occurs before migration is complete, AppPorts attempts to roll back. If rollback cannot finish safely, it preserves copies and shows their retained paths.

If migration is complete but removing the local safety backup fails, the mounted data remains usable. AppPorts explicitly shows the path of the backup that still needs cleanup; you do not need to migrate again.

After migration, `mount` shows the volume mounted directly at the container path:

```
/dev/disk7s5 on /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files (apfs, local, nodev, nosuid, journaled, noowners, nobrowse)
```

## First Launch After Migration <a href="#first-launch-after-migration" id="first-launch-after-migration"></a>

macOS asks whether the app may access files on a removable volume. **Click Allow.** This is a normal macOS check because the data is on external storage, and it prompts only once.

If you deny access, the app sees no data and appears empty. To fix this, find the app under System Settings → Privacy & Security → Files and Folders (or Removable Volumes) and enable access. Alternatively, run `tccutil reset SystemPolicyRemovableVolumes <Bundle ID>` in Terminal to prompt again next time.

System apps under `/System/Applications` are silently denied without a prompt. AppPorts does not migrate these apps.

## Daily Use <a href="#daily-use" id="daily-use"></a>

**Connect the external drive before opening the app.** When the drive is absent, the mount point is an empty, locked directory (mode 000). The app sees empty data, without an error, and cannot write a second local copy. When the drive reconnects, AppPorts remounts the volume and the data returns.

**These data volumes are normally hidden in Finder.** AppPorts mounts them with `nobrowse`, so they do not appear in the Finder sidebar or on the desktop. For a second or two after connecting the drive, macOS may mount them under `/Volumes` and briefly show an icon; it disappears when AppPorts remounts them. Volumes migrated by earlier versions that still appear in Finder will be hidden in place the next time AppPorts starts or the drive connects, without an unmount/remount cycle. They remain visible in Disk Utility as `AppPorts-…`. **Do not erase or delete them there**: they contain your migrated data.

**Before unplugging, quit the app, then click "Unmount" in AppPorts or eject the external drive in Finder.** Unplugging directly may lose the last few seconds of writes and require database repair. In our unplug tests, APFS volumes lost only the last few transactions; see [Experiment: Unplug Test](../research/unplug-test.md).

**When automatic reconnection happens:**

- With AppPorts running: at startup and whenever a volume is connected, it mounts online volumes whose records are not currently mounted.
- With AppPorts closed: after a successful migration, a login agent silently remounts volumes at login and whenever external storage connects, then exits. It is automatically uninstalled when the last record is restored.
- If you open an app immediately after login, it may still see an empty directory for ten or more seconds because the system starts the agent after login items. Quit and reopen the app. The fallback is that the mount point stays empty: even if the app starts first, it cannot write a separate local copy. It recovers once the volume is mounted; WeChat recovered in all three tests.

{% hint style="warning" %}
**Older systems such as macOS 12 require an administrator password**

macOS 27 allows ordinary users to mount volumes at paths in their own directories; tests on macOS 12 did not. AppPorts retries with the system administrator password prompt when it encounters this error, usually asking once per migration. The login agent has no interface and cannot show the prompt, so automatic remounting after login is unavailable on these systems. Open AppPorts to enter the password, or click "Mount" in App Data. The exact version between 13 and 26 that relaxed this restriction has not been verified.
{% endhint %}

## Statuses and Actions <a href="#statuses" id="statuses"></a>

| Status | Meaning | Available Actions |
|--------|---------|-------------------|
| Mounted | The volume is mounted at the original directory; the app can read and write normally | Unmount, Restore |
| Awaiting mount | The volume is online but not mounted, for example just after connecting or after a manual unmount | Mount, Restore |
| Drive Not Connected | The data volume cannot be found, usually because the drive is disconnected | Connect the drive for automatic reconnection. If it is already connected, see [Troubleshooting](#troubleshooting) |

**Restore** copies the data back to this Mac, then removes the volume and record. Keep the external drive connected:

- AppPorts checks local free space first. If there is not enough, it stops and leaves the volume and record unchanged.
- After copying, AppPorts first converts the mount record to information about pending cleanup to prevent automatic remounting, then switches back to the local directory. It deletes only the empty mount-point directory left after unmounting, never directories recursively.
- If the switch back to the local directory does not finish, the staged local copy and external volume are preserved. The local copy remains in a hidden `.appports-restore-staging-…` folder in the same directory. Follow the retained paths and guidance shown by AppPorts.
- If the local directory has been restored but deleting the external volume or updating the cleanup record fails, AppPorts explicitly reports that restoration is complete but cleanup is not. Retry cleanup from the Data Directories page; do not repeat migration or restoration.

If you cannot confirm whether a copy still exists, you can choose "Remove Cleanup Record Only"; this does not delete local backups or external volumes or remount anything, and any remaining copies must be cleaned up manually.

If local files appear inside the mount-point directory—for example, if an app managed to write there while the drive was absent—AppPorts refuses to mount over them. Move the files elsewhere before mounting.

## Before Uninstalling or Moving AppPorts <a href="#before-uninstalling-or-moving-appports" id="before-uninstalling-or-moving-appports"></a>

Mount migration relies on the AppPorts login agent to reconnect volumes after each login. **Before deleting AppPorts, use "Restore" in App Data to return mount-migrated directories to this Mac.** If you delete AppPorts without restoring, the data remains intact on the external volumes, but nothing remounts them at login and the app sees an empty directory. Reinstall and open AppPorts once to recover.

If you are only updating or moving AppPorts, open the new copy once. It updates the agent to point to the new location automatically.

## Troubleshooting <a href="#troubleshooting" id="troubleshooting"></a>

| Symptom | What to Do |
|---------|------------|
| "Drive Not Connected" even though the drive is connected | In Disk Utility, check for `AppPorts-…` volumes on the drive. If present, refresh in the AppPorts toolbar or reconnect the drive. If the volume was deleted, the directory's data is no longer on the drive and must be restored from a backup |
| The app opens with no data | Check whether the directory is "Mounted". If not, connect the drive or click "Mount". If it is mounted but empty, check whether you denied access on the [first launch](#first-launch-after-migration) |
| "Mount" reports a nonempty mount point | Local files occupy the directory. Identify and move them elsewhere, then mount again |
| Migration or restoration says the background agent is connecting external storage | The login agent is mounting volumes; wait a few seconds and try again |

## Why Disk Images Are Not Used <a href="#why-disk-images-are-not-used" id="why-disk-images-are-not-used"></a>

For exFAT users, we tested storing an APFS disk image (sparsebundle) on the drive and mounting it. It avoided the permission prompt, performed similarly, and worked on any host format.

Then we unplugged the USB drive while writing data. The APFS volume lost only a few recent transactions and its database was recoverable; **the entire disk image became unopenable in both rounds**, making all its data inaccessible. Its own directory metadata is rewritten every few seconds; interrupting that write leaves fragments without a directory. See the complete [unplug test results](../research/unplug-test.md) and the user-oriented explanation in [Why External Drives Must Use APFS](../why-apfs.md).

AppPorts therefore supports APFS volumes only.

## Technical Details <a href="#technical-details" id="technical-details"></a>

### Automatic Remount Timing <a href="#automatic-remount-timing" id="automatic-remount-timing"></a>

- The login agent is `~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist` and runs `AppPorts --mount-agent`. It also watches `/Volumes` and runs again when external storage appears. On the tested boot (2026-09-22), the sequence was login complete → agent starts after 4.6 seconds → both volumes return to their container paths after 18 seconds. This was about 19 seconds faster than the earlier version, but login apps started after about 3 seconds. See [Experiment: Mounting Before Login](../research/prelogin-mount.md) for the timeline and why mounting cannot happen earlier.
- **The agent keeps waiting when the drive is slow to appear.** It watches `/Volumes` inside the process and retries on a **real change**, rather than polling at a fixed interval. A busy boot may take minutes to recognize the drive; on 2026-09-23 it took 2 minutes 33 seconds. Fixed polling either wastes `diskutil` calls during the busiest period or misses app startup. If no event arrives, it checks every 20 seconds as a fallback, within a total 180-second window. It does not hold the lock while waiting. Measured time from volume appearance to completed mount: about 1 second.
- **Check `/Volumes/<卷名>` before mounting.** At boot or connection, macOS almost always mounts the volume there first. `statfs` plus a volume-root marker read identifies it in microseconds and avoids one `diskutil info` call. On the 2026-09-23 boot, that query took **9 seconds**, the slowest step in the chain. AppPorts falls back to `diskutil` only when it cannot identify the volume, for example if the system renamed it or the marker is missing.
- **Verify after mounting.** If macOS has already mounted a volume under `/Volumes`, `diskutil mount -mountPoint` can **ignore the requested mount point, still print `mounted`, and return 0**. AppPorts verifies the destination every time. If it is wrong, it queries the current location, unmounts the volume from `/Volumes`, and retries, up to 3 rounds. This happened on both 2026-09-21 and 09-23; the earlier implementation gave up after detecting failure, and WeChat then saw an empty directory.
- **Only operate on AppPorts volumes.** Before mounting, unmounting, or restoring, AppPorts checks the mount point's Volume UUID against the record. If another volume occupies the path, it stops without unmounting, overwriting, or deleting it.
- The agent and AppPorts share a cross-process lock at `~/Library/Application Support/AppPorts/operation.lock`. If AppPorts is migrating, unmounting, or restoring, the agent waits up to 120 seconds, then skips that round until the next connection or login. AppPorts also refuses to start an operation without the lock and asks you to retry. The lock is held only during each mounting round, not while waiting minutes for a drive, so other AppPorts operations remain available.
- If the migration record file cannot be read, AppPorts preserves it and refuses to add or delete records, rather than treating it as empty and overwriting it.
- `/etc/fstab` is not used: the `UUID=` form failed in tests, device numbers change after reconnection, and root mounting at boot is subject to the same permission controls.

### Spotlight Indexing on the Volume <a href="#spotlight-indexing-on-the-volume" id="spotlight-indexing-on-the-volume"></a>

The system treats volumes mounted at container paths as ordinary external volumes and builds indexes for them. The `.Spotlight-V100` folders on two WeChat volumes totaled 110 MB and were still being rewritten after boot. Indexing this app data is unnecessary, so:

- AppPorts writes an empty `.metadata_never_index` file at the volume root after creation so mds skips the whole volume. Any `.Spotlight-V100` already created is also removed.
- The marker stays with the volume and does not need to be recreated after moving the mount point or restoring a mount migration.
- Volumes migrated before this version receive the marker automatically on the next mount.
- The marker is not copied back to the local directory. Restoration skips `.metadata_never_index`, `.fseventsd`, and `.Spotlight-V100`.

### Diagnostic Commands <a href="#diagnostic-commands" id="diagnostic-commands"></a>

```bash
# 挂载记录
plutil -p ~/Library/Application\ Support/AppPorts/container-mounts.plist

# 当前挂载
mount | grep Containers

# 登录代理
launchctl print gui/$(id -u)/com.shimoko.AppPorts.container-mount

# 卷根有没有防索引标记；系统的索引状态应为 Indexing disabled
ls -la "<挂载点路径>/.metadata_never_index"
mdutil -s "<挂载点路径>"

# 手动重挂（要在有完全磁盘访问权限的终端里执行；旧系统前面加 sudo）
diskutil mount nobrowse -mountPoint "<挂载点路径>" <Volume UUID>
```

## Related Documentation <a href="#related-documentation" id="related-documentation"></a>

- [Why External Drives Must Use APFS](../why-apfs.md)
- [Container Data, Sandboxing, and Signing Identity](container-identity.md)
- [Upgrading to macOS 27](../macos-27.md): switching from the old workflow
- [Experiment: Mount Points](../research/sandbox-mountpoint.md): the original experiments behind this feature
