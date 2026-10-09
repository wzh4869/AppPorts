---
icon: "plug"
description: "Compare drive removal effects on APFS volumes and disk images."
layout:
  width: "default"
  outline:
    visible: true
---

# Experiment Log: Impact of Unplugging the Drive on APFS Volumes and Disk Images

This page is the raw record of a **controlled experiment**, used to answer a question that came up when choosing the backend for mount migration:

> If container data is kept in an APFS volume on the external drive, versus in an APFS disk image (sparsebundle) on the external drive, and the drive is pulled out mid-write, how much does each lose?

The answer: **the entire disk-image volume became unusable in both test rounds**, while the APFS volume lost only its last few transactions. For the user-facing explanation, see [Why the External Drive Must Be APFS](../why-apfs.md).

## Environment <a href="#environment" id="environment"></a>

| Item | Value |
|------|-----|
| System | macOS 27.0 (26A428), arm64 |
| Test drive | 64 GB USB flash drive (U352), used after `diskutil eraseDisk APFS APTEST GPT` |
| APFS volume | Newly created with `diskutil apfs addVolume` in the test drive's APFS container, `diskutil mount -mountPoint ~/appports-test/usb-apfsmnt` |
| Disk image | `hdiutil create -type SPARSEBUNDLE -fs APFS -size 20g`, stored at the root of the test drive, `hdiutil attach -mountpoint ~/appports-test/usb-imgmnt -nobrowse` |
| Write workload | Python script: SQLite `synchronous=FULL` + WAL, inserting in a loop and committing each row individually, while also writing a 64 KB file every 50 commits; each commit writes a line `committed N` to a log |
| Unplug method | Pulled the USB connector directly, without ejecting |
| Date | 2026-09-19 |

## Round 1: Plain fsync <a href="#round-1-plain-fsync" id="round-1-plain-fsync"></a>

The two writer processes ran in parallel for 12 seconds, then the drive was pulled.

| | Last commit before unplugging | After plugging back in |
|---|---|---|
| APFS volume | 7177 | `yank.db` reports `database disk image is malformed`; `sqlite3 .recover` recovered 7172 rows, `max(id)=7172`; all 50 files present |
| Disk image | 25574 | `hdiutil attach` reported "无可装载的文件系统" (no mountable file systems); `fsck_apfs` reported `container superblock is invalid`; the band 0 file was only 3.26 MB (it should normally be 8 MB) |

The image's commit count is more than three times the volume's, which shows that its writes mostly stayed in the host's page cache and never actually reached the disk.

## Round 2: `F_FULLFSYNC` <a href="#round-2-f-fullfsync" id="round-2-f-fullfsync"></a>

The writer script added `pragma fullfsync=1; pragma checkpoint_fullfsync=1`, which is how SQLite on macOS truly forces writes through to the medium (most apps don't enable it). Both sides became much slower.

| | Last commit before unplugging | After plugging back in |
|---|---|---|
| APFS volume | 1906 | `integrity_check` = ok, 1905 rows, `max(id)=1905` |
| Disk image | 373 | Still could not be mounted; superblock invalid |

Even with the strictest possible flushing at the application layer, the checkpoint area of the APFS file system inside the image (which lives in band 0) was still left half-written.

## Round 3: ASIF (Aborted) <a href="#round-3-asif-aborted" id="round-3-asif-aborted"></a>

macOS 26 and later offer ASIF, a single-file sparse image format (`diskutil image create blank --format ASIF`). After mounting one, we wrote to it for 12 seconds (8000 commits) and decided to abort before pulling the drive: ASIF is only available on 26+, so it is meaningless for the target users (12 through 26), and, like APFS volumes, it requires the host to be APFS, so it does not solve the exFAT problem.

## Performance Comparison (Before Unplugging, Same USB Flash Drive) <a href="#performance-comparison-before-unplugging-same-usb-flash-drive" id="performance-comparison-before-unplugging-same-usb-flash-drive"></a>

| Workload | Internal SSD | APFS volume | sparsebundle (host: APFS) | sparsebundle (host: exFAT image) | Writing directly to exFAT |
|---|---|---|---|---|---|
| SQLite, 2000 individual commits | 0.07 s | 0.35 s | 0.10 s | 0.17 s | 1.69 s |
| 2000 small 4 KB files | 0.08 s | 0.10 s | 0.08 s | 0.09 s | 0.76 s |
| 256 MB sequential write + fsync | 0.07 s | 0.31 s | 0.37 s | 0.67 s | 0.80 s |

The image's database commits were even faster than the APFS volume's, precisely because it was not really reaching the disk. The exFAT column shows that even if a database could be placed directly on exFAT, its performance would be unsuitable for workloads like chat history.

## Other Observations <a href="#other-observations" id="other-observations"></a>

- The image approach **does not trigger** the "Removable Volumes" TCC authorization: the built-in Stickies (a platform app) was silently denied on the APFS volume, but read and wrote normally on the image, with no deny of any kind in the logs.
- The image does not give space back after files are deleted: after writing and then deleting 5 GB, the image still took up 5.6 GB and needed `hdiutil compact`.
- After the unplugging, `fsck_apfs` reported both of the test drive's own APFS volumes as healthy; the corruption occurred only inside the image.

## Conclusions <a href="#conclusions" id="conclusions"></a>

| | APFS volume | Disk image |
|---|---|---|
| Loss when unplugged | The last few transactions; the database is repairable | The entire volume |
| External drive format | Must be APFS | Any |
| TCC authorization prompt | Once, the first time | None |
| Performance | Native | Comparable (because writes don't reach the disk) |

AppPorts therefore offers only the APFS volume backend. The image approach's other advantages are not enough to offset "unplug once and the whole volume is gone."

## Cleanup <a href="#cleanup" id="cleanup"></a>

The writer processes have been stopped, the image and the test volume deleted, `~/appports-test/` deleted, and the Stickies container data used as a control restored exactly as it was. The test drive has been kept as an empty APFS drive.
