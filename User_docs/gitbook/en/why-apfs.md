# Why External Drives Must Use APFS

{% hint style="success" %}
**The key point**

Starting with 1.9.0, AppPorts migrates `~/Library/Containers/` data, such as WeChat chat history, by creating a volume in the external drive's APFS container and attaching it directly to the original directory. Only an APFS external drive supports this approach. We also tested disk images as a workaround for exFAT / NTFS drives, but **unplugging the drive made the entire image unusable**, so that option is not offered.

**If your external drive is not APFS, you do not have to change it now.** Apps and ordinary data directories can still be migrated; leave container data on this Mac and use the apps normally. When you want to migrate container data later, follow [Prepare an APFS External Drive](#prepare-apfs). Free space inside an exFAT partition does not mean you can split off a new partition directly.
{% endhint %}

## Which Operations Require APFS? <a href="#which-operations-require-apfs" id="which-operations-require-apfs"></a>

| What You Want to Do | External Drive Format Requirement |
|--------------------|-----------------------------------|
| Migrate the app itself (move its `.app` to the external drive) | No format requirement; exFAT is fine |
| Migrate ordinary data directories (`Application Support`, caches, tools such as `~/.npm`, and custom directories) | No format requirement |
| Migrate **container data** (`~/Library/Containers/`, `~/Library/Group Containers/`, used by WeChat, QQ Music, and App Store apps) | **APFS required** |

Only the third category is affected, although it often contains the largest data you most want to move.

## Why Container Data Is Different <a href="#why-container-data-is-different" id="why-container-data-is-different"></a>

Most Mac apps are sandboxed: the system gives each app a dedicated folder under `~/Library/Containers/` and confines its file access to that folder. This is part of macOS security, and apps distributed through the App Store must use it.

AppPorts used to copy a folder to the external drive and leave a "shortcut" (symbolic link) at the original location. This works well for ordinary data directories, but **it never truly worked for sandboxed apps**:

- The system checks **where the shortcut points**, not where it sits. An external-drive destination is outside the app's dedicated folder, so access is denied.
- The old workflow appeared to work because an extra re-signing step removed the app's sandbox identity. Once the app was no longer sandboxed, that restriction no longer applied.
- The cost becomes apparent on macOS 27: when the system checks whether the app is entitled to access that folder, the altered identity may no longer match, and the app quits within a second of opening. This is confirmed for WeChat; QQ Music still opens at present. Reinstalling the app is required to repair it. See [Upgrading to macOS 27](macos-27.md) for the background.

The new approach therefore has one central requirement: **the data must be on the external drive while remaining inside the app's dedicated folder.**

## How the New Approach Works <a href="#how-the-new-approach-works" id="how-the-new-approach-works"></a>

Instead of a shortcut, a portion of the external drive is **mounted directly at the original folder**. Think of the folder staying in the same place while its "floor" is replaced by the external drive.

- The path seen by the app stays exactly the same, so the system's checks pass normally.
- The app's signature is unchanged, byte for byte. No re-signing is needed, avoiding the associated problems with future system upgrades.
- When the drive is absent, the folder is empty. The app sees no data and cannot write new local data that would create a second copy.

To mount storage at a folder, that storage must be an independent **volume**. APFS can **add multiple volumes within one APFS container, sharing its free space**. There is no need to preallocate a size for each volume or repartition the drive. AppPorts uses this capability to create a dedicated volume for each migrated directory. Adding a volume is different from creating a new partition on a physical disk.

An exFAT or NTFS partition cannot contain new APFS volumes in this way. To keep exFAT or NTFS alongside APFS on one drive, APFS needs a separate partition: use existing unallocated space, or first shrink the existing partition with a tool that supports its file system. If neither is possible, back up and repartition. AppPorts does not modify disk partitions for you.

## The Workaround We Tested <a href="#the-workaround-we-tested" id="the-workaround-we-tested"></a>

Many users have exFAT drives, so we seriously considered a workaround: place a disk-image file on exFAT—a sparsebundle, like those used for Time Machine backups to network drives—format its contents as APFS, and mount the image at the folder.

Initially this looked promising. Tests on macOS 27 in September 2026 showed that:

- The host drive did not need to be APFS; any format could store the image.
- The app's first access did not trigger a Removable Volumes permission prompt, unlike an APFS volume, which prompts once.
- Read and write speeds were similar to an APFS volume.
- Even platform apps such as the built-in Stickies app could use it; the APFS-volume approach does not work for platform apps.

Then we tested a common real-world event: **unplugging the drive while data was being written**. We formatted a 64 GB USB drive as APFS and prepared both an APFS volume and a disk image on it, each mounted at a folder. Two programs continuously wrote databases, much like WeChat and QQ Music storing chats and playlists. After a little over ten seconds, we unplugged the drive, reconnected it, and checked what remained.

| | Rows Written Before Unplugging | After Reconnecting |
|---|---|---|
| APFS volume, round 1 (normal writes) | 7177 | The database reported corruption once; the recovery command recovered all 7172 rows. The file system was intact |
| APFS volume, round 2 (app forces writes to disk) | 1906 | 1905 rows intact; only the last row was lost |
| Disk image, round 1 (normal writes) | 25574 | **The image would not open**; all its contents were inaccessible |
| Disk image, round 2 (app forces writes to disk) | 373 | **The image still would not open** |

The difference was between losing a few records and losing access to everything.

The reason is straightforward: the disk image consists of many 8 MB files on the external drive. Its own "directory book" is stored in the first file and rewritten every few seconds. When the drive is unplugged, the external file system protects the files themselves, but does not guarantee that partially written contents inside them are complete. If that directory book is half-written, the entire image becomes fragments without a directory. Forcing database writes to disk cannot fix this, because the problem is in the image layer, outside the app's control.

People who use Time Machine with a network drive may have encountered "the backup is damaged; create a new backup". This is the same kind of problem. A backup can be recreated; lost chat history cannot.

We therefore ruled out disk images after testing. A data migration tool cannot offer an option that may make everything disappear after one unplug, even if it is more convenient in other respects.

## What to Do Now <a href="#what-to-do" id="what-to-do"></a>

First decide **whether you are migrating container data**. If not, nothing needs to change. If you are, choose based on the current drive:

| Your Situation | Recommendation |
|----------------|----------------|
| The drive already uses unencrypted APFS | Click "Mount migration" in "App Data" |
| The drive uses exFAT / NTFS and you want to leave it alone | **Keep As Is**: leave container data on this Mac and migrate everything else normally. This is a fully supported way to use AppPorts |
| You have another APFS drive or want to prepare a dedicated one | Select that drive as external storage in AppPorts, then migrate the container data |
| You want to make room for APFS on the current drive | Follow [Prepare an APFS External Drive](#prepare-apfs) below; back up first |
| The drive uses encrypted APFS | Not supported yet; see [Encrypted External Drives](#encrypted-drives) below |

If you are unsure, click "Mount migration" in AppPorts. It first checks the external storage without making changes, then explains which situation applies.

**Check the drive's format**: select the drive in Finder, press `⌘ I`, and look at Format. "APFS" meets the format requirement. "ExFAT", "NTFS", or "Mac OS Extended" (HFS+) falls into the non-APFS category above.

## Prepare an APFS External Drive <a href="#prepare-apfs" id="prepare-apfs"></a>

{% hint style="warning" %}
**Before modifying the disk**

Back up the drive's data before using any of the methods below. AppPorts does not erase disks or change partitions for you.
{% endhint %}

**If there is no important data on the drive**: open Disk Utility, select the drive, click Erase, choose "APFS" as the format and "GUID Partition Map" as the scheme. Erasing removes everything on the drive.

**If you want to preserve the existing partition and its data**: first confirm that the disk uses GUID Partition Map, then identify the situation below. The available capacity shown by Finder is free space inside the file system, **not unallocated space outside the partition**.

| Current Situation | How to Prepare APFS Space |
|-------------------|---------------------------|
| An APFS container already exists | Select one of its volumes in AppPorts. AppPorts adds APFS volumes for migration automatically; no repartitioning is needed |
| Enough usable unallocated space exists for a new partition | Create an APFS partition there without erasing the existing partition. Check the scope of changes shown by Disk Utility first |
| exFAT occupies the whole drive, with no unallocated space | Neither macOS Disk Utility nor Windows Disk Management can shrink exFAT. With built-in tools, you must back up, erase and repartition, then restore the files |
| NTFS partition with no unallocated space | macOS cannot shrink NTFS while preserving data. First shrink it in Windows Disk Management; if this creates unallocated space, return to macOS and create an APFS partition. How much it can shrink depends on file layout and other constraints |
| Mac OS Extended (journaled HFS+) partition or APFS container | macOS supports resizing while preserving data. If space and partition layout permit, shrink it and create an APFS partition. Back up first anyway |

If the disk does not use GUID Partition Map, do not apply the add-partition steps directly. Back it up and repartition using the GUID scheme first. Once it is ready, point AppPorts' external storage path to the APFS volume.

References: local `man diskutil` documents that `resizeVolume` requires **journaled HFS+**; APFS uses `apfs resizeContainer`. [Microsoft's instructions for shrinking a basic volume](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/shrink-a-basic-volume) explicitly cover NTFS or volumes with no file system, not exFAT. A third-party tool's ability to shrink exFAT without data loss must be checked separately; it is not a built-in system capability.

**If the drive must also work with Windows**: Windows cannot read or write APFS by default. Use two partitions: exFAT for sharing with Windows and APFS for AppPorts. If exFAT already fills the disk, built-in tools cannot carve an APFS partition directly out of it. Back up and repartition first.

## Encrypted External Drives <a href="#encrypted-drives" id="encrypted-drives"></a>

Mount migration creates a new data volume in the drive's APFS container, and the new volume **does not inherit** the existing volume's password. Migrating without accounting for this would move chat history protected by FileVault on this Mac to a volume anyone could read simply by connecting the drive. Until automatic unlocking at login and password management are implemented, AppPorts does not offer mount migration on encrypted APFS drives and does not silently create an unencrypted volume.

Your options:

- **Keep As Is**: leave container data on this Mac, protected by this Mac's FileVault.
- **Use an unencrypted APFS drive or partition**: migrate with the understanding that this data will not be encrypted on the external drive.

## Classic Data Migration Mode <a href="#classic-data-migration-mode" id="classic-data-migration-mode"></a>

"Classic data migration mode (not recommended)" in Settings restores the symbolic-link and re-signing workflow from 1.8.1. It does not depend on APFS, but retains all the old risks: sandboxed apps may not open on macOS 27, and login sessions may be lost. It exists for users who already rely on the old workflow; **do not enable it just to bypass the APFS requirement**. See [Settings](settings.md#classic-data-migration-mode).

## Common Questions <a href="#common-questions" id="common-questions"></a>

### What About Container Data Previously Migrated to exFAT? <a href="#what-about-container-data-previously-migrated-to-exfat" id="what-about-container-data-previously-migrated-to-exfat"></a>

The old migration used symbolic links and re-signing, regardless of the drive format. Its problem is re-signing, not the format. See [Upgrading to macOS 27](macos-27.md) for recovery steps. If you still want the container data on external storage afterward, follow [Prepare an APFS External Drive](#prepare-apfs).

### Why Not Offer an "I Accept the Risk" Option for exFAT? <a href="#why-not-offer-an-i-accept-the-risk-option-for-exfat" id="why-not-offer-an-i-accept-the-risk-option-for-exfat"></a>

The risk is losing everything after one unplug, rather than occasionally losing a little data. Unplugging is a normal part of using portable storage. Once chat history is gone, having warned about it beforehand does not help.

### Does Switching to APFS Affect Read and Write Speeds? <a href="#does-switching-to-apfs-affect-read-and-write-speeds" id="does-switching-to-apfs-affect-read-and-write-speeds"></a>

No. APFS is the native macOS format and is generally faster than exFAT on SSDs. In our tests on the same USB drive, database writes to an APFS volume were about ten times faster than writing directly to exFAT.

### Can I Use HFS+ (Mac OS Extended)? <a href="#can-i-use-hfs-mac-os-extended" id="can-i-use-hfs-mac-os-extended"></a>

Not directly for mount migration. HFS+ lacks APFS's multiple volumes with shared space. However, macOS built-in tools can shrink journaled HFS+ while preserving data; when conditions permit, this creates space for a new APFS partition. This differs from exFAT. Back up first, and see [Prepare an APFS External Drive](#prepare-apfs).

## Related Documentation <a href="#related-documentation" id="related-documentation"></a>

- [Mount Migration](datamigrae/mount-migration.md): how to use the new method
- [Experiment: Unplug Test](research/unplug-test.md): the original experimental data
- [Upgrading to macOS 27](macos-27.md): why the old method fails on 27
- [External Storage Guide](storage-guide.md): general advice on interfaces, capacity, and file systems
