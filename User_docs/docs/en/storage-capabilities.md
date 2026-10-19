# What the destination cannot store about an app

When you move an app to an external drive, the file contents almost always make it across. What differs is **which attributes a filesystem can record**. When the destination lacks a capability, AppPorts explains this before migrating; afterwards the app usually still opens and runs, but that part of the information cannot be preserved.

This page covers why each case happens, what it means, and what to do.

## Summary {#summary}

| Missing on the destination | What happens after migration | Recommendation |
| --- | --- | --- |
| Access control lists (ACL) | The app's fine-grained access rules are lost; ordinary permission bits remain | Most apps are unaffected; apps with a privileged background service should use APFS |
| Hard links | Files shared inside the app are stored as separate copies, using more space | Usable; only costs extra space |
| Resource forks | A few apps may lose custom icons or legacy localized resources | Usable; appearance may be incomplete |
| POSIX permission bits | All file permissions become the drive's fixed default | Usable; apps that depend on specific permissions may misbehave |

In short: **these are all "works, but incomplete."** The cases that genuinely refuse a migration are different — see [when a migration is refused](#refused).

## Why this happens {#why}

Filesystems are designed for different goals. APFS is the native macOS filesystem and stores owners, permissions, ACLs, hard links, resource forks and extended attributes in full. The formats below were designed for cross-platform exchange, or deliberately simplify these concepts:

- **exFAT**: designed for USB drives and cross-platform exchange. No owner field, no ACLs, no hard links, fixed permissions, and resource forks cannot be written. macOS stores extended attributes in hidden sidecar files, so ordinary attributes do work — resource forks do not.
- **FAT32**: more limited than exFAT; a single file cannot exceed 4 GB.
- **HFS+ mounted with ownership ignored**: stores owner fields, but new files are recorded under a placeholder user.

So the problem is not that the drive is bad — it is that the drive **was not designed to store this information**. Put an app on it and the file contents are correct while the metadata is not.

## What each one means {#details}

### Access control lists (ACL) {#acl}

ACLs are finer-grained rules than read/write/execute — for example, "allow this background service to read this file." Sandboxed apps and apps with privileged services use them.

When lost, files fall back to ordinary POSIX permission bits. The vast majority of apps are unaffected, but **apps that rely on ACLs to authorize a background service** may refuse to work and suggest fixing permissions — and on such drives, permission changes are silently ignored by the system: they appear to succeed and do nothing.

### Hard links {#hardlinks}

Hard links let multiple paths point at the same data without duplicating it. Apps use them to share resources between components — the same icon referenced by several internal apps, for instance.

When the destination cannot create hard links, AppPorts **materialises them as independent copies**. The app runs normally; the cost is **extra space**. The log records how many were separated.

### Resource forks {#resource-fork}

Resource forks are a legacy macOS feature used for icons and old-style localized strings. Most modern apps use ordinary files, but some older apps and localization resources still rely on them.

When they cannot be stored, that part is lost — visible as **a missing icon or incomplete interface text**, not as a broken program.

### POSIX permission bits {#permissions}

Permission bits decide who may read, write and execute. Some filesystems reject `chmod` and report a single fixed mode for everything.

When lost, every file has the same permissions. Ordinary apps are unaffected, but **apps that depend on specific permissions** (for example, a file readable only by its owner) may misbehave.

## How AppPorts decides whether a drive is suitable {#check}

Before migrating, AppPorts **actually probes** the destination's capabilities rather than guessing from the format name. It creates temporary entries at the destination, attempts to write an ACL and a resource fork, create a hard link, and set permission bits, then removes those entries. The same drive is therefore identified correctly even if it is mounted differently.

When a capability is missing, a warning appears before the migration listing exactly what is unavailable. You can continue, or choose another drive.

## What to do in each case {#solutions}

**If the app is ordinary** (no ACL-dependent authorization, no privileged background service): continue. The practical effect is usually a little extra space, or a missing icon.

**If the app has a privileged background service** (some system utilities, VPNs, proxy tools): prefer an APFS-formatted drive, or keep its data on the internal disk. These apps are the most likely to refuse work after ACLs or permission bits are lost.

**If you are short on space**: separated hard links make the copy larger. Move the app back, free space, then migrate again — or use a larger drive.

**If you need every attribute preserved**: the only reliable answer is an APFS-formatted destination. APFS stores real ownership even when mounted with ownership ignored, making it the most complete choice on macOS.

> Erasing a disk deletes data on the selected object. Confirm your backup is usable before changing formats, and do not reformat an entire drive just to bypass a warning.

## When a migration is refused {#refused}

Everything above is "works, but incomplete." There is another class of case where AppPorts stops and keeps the originals, because continuing would genuinely lose something:

- The app **itself carries** an ACL that the destination cannot store — that is a real authorization rule and cannot be pretended away.
- The destination contains content the source does not, or a file changed during the copy — correctness cannot be proven.
- The destination disconnects or becomes read-only during the migration.

When you see one of these, keep the original drive and the existing copies, follow the on-screen guidance, and retry. Do not delete copies by hand.

## Related reading {#related}

- [External drives and daily use](/docs/storage-guide): APFS requirements, encrypted drives, file owners
- [Moving apps](/docs/core): migration flow and statuses
- [FAQ and troubleshooting](/docs/faq): diagnosing problems after migration
