# AppPorts migration safety — accepted specification and execution plan

The user approved both conversational plans on 2026-10-01. This document preserves the combined requirements; the later hierarchy-compatibility plan takes precedence. The user authorizes autonomous implementation choices and requires decisions, progress, and test evidence to be recorded. Do not ask routine implementation questions. On a wake-up message acknowledge `ok` and resume unfinished work.

## Constraints and accepted product decisions

- Work in the isolated worktree on `codex/migration-safety`; preserve the dirty primary checkout. No real running applications, user containers, real mounts, signatures, TCC, or LaunchAgents may be changed during implementation/testing. Use synthetic fixtures and owned APFS images only.
- macOS 12 minimum; no new privileged metadata helper. Preserve application-bundle copying behavior and existing explicit classic-mode signing consent.
- App-data view: checkbox `显示锁定目录结构` next to `显示零字节目录`, default off, persisted. Locked nodes exempt from zero-byte filtering when enabled; visible children retain contextual ancestors when disabled. Managed/recovery/error items remain visible. Do not add this switch to the tool-directory tab.
- Show formerly hidden WeChat branches, but do not broaden its existing new-migration whitelist. System structural locks and WeChat compatibility restrictions have different reasons.
- After migration/restore keep the original copy until explicit user cleanup. Retention is a normal successful state, not a cleanup failure; do not claim the occupied source space has been freed.

## Task 1: Shared policy, historical discovery and locked structure UI

Create DataPathPolicy with structured role/reasons and per-operation capabilities. Protect ordinary container root and Data root plus exact Data-relative paths Documents, Library, Library/Application Scripts, Library/Application Support, Library/Caches, Library/Images, Library/Logs, Library/Preferences, Library/Saved Application State, SystemData, tmp. Lock the node, not all descendants. Group Containers have their own root rule. WeChat new candidates remain xwechat_files children and Application Support/com.tencent.xinWeChat; xwechat_files itself remains compatibility-locked. Discover locked branches and children without blindly crossing managed mounts/symlinks. Merge persistent historical records independently of whitelist/depth/missing paths; do not trust appName or logs as identity. Existing links (including needs-normalization) need independently calculated restore capability.

UI uses the policy, existing DataDirTree ancestor retention and non-duplicated size accounting. New filtering must not affect execution rights. Explicit filters/search still apply. Reasons must participate in equality/UI updates. All user-facing text follows the existing localization catalog.

## Task 2: Strict data-tree copier

Implement a data-only TreeCopySession (leave FileCopier app-bundle defaults unchanged) producing a Codable verified baseline. One session includes root and all children (restore no longer copies only root children). Preserve content, ACL, uid/gid, 07777 mode, xattrs including empty/resource fork, birth/modify time, supported flags and in-tree hardlink topology. Copy links as links; do not traverse mounts. Reject boundary-crossing hardlinks, changed final resolution of external relative symlinks, unhydrated/special/unsupported data, inaccessible metadata, immutable/append/system-restricted items rather than silently skipping. Do not promise inode/ctime/atime/physical compression equality. Apply restrictive metadata last and verify. Baseline describes data actually copied and verified, never a later untransferred source state. Expose snapshot/verification APIs for retention checks; preserve cancellation and progress.

## Task 3: Durable transfer and retention state

Extend the atomic record document to schema 3 with generic data-transfer transactions/retained copies in addition to mounts. Read legacy arrays/schema 2; reject corrupt/future documents for mutating operations (do not treat as empty). Retain legacy cleanup items without inventing a baseline. Register intent before first side effect, record switching before rename/mount, and persist awaiting-user-verification. Track source/target/backup path and stable identities, volume UUID, operation and policy version, stage and verified baseline reference. Stages need to distinguish preparing/copying/verified/switching/awaiting verification/cleanup requested/recovery needed. Restart never automatically deletes retained originals; record writes must fail closed and be idempotent.

## Task 4: Integrate safety into every data operation

Apply policy and topology guards to mount migration, symlink migration, createLink/relink, normalize, remount and cleanup regardless of UI flags or custom-tab entry. Topology covers current mounts, online/offline records, symlink management, transactions, staging and retained copies, including ancestor/descendant relations and aliases. Parent already migrated prevents new child migration; child managed prevents parent migration/normalization. Preserve contradictory history as needsRecovery, never overwrite it by path.

Use strict copying for both migration forms and both restores. Originals retained by default; associated app and identifiable writers checked, source changes block switch; post-switch changes preserve both copies and report conflict. Explicit cleanup verifies old copy against copied baseline, ownership/identity/topology and known occupancy; active new target can legitimately change. No force-delete-on-difference. No claim of atomic isolation from arbitrary uncooperative future writers.

Historical structure locks must not prevent recovery: separate ordinary remount from private recovery mounting at an isolated staging mount. Do not add public ignorePolicy. Old forbidden active mounts remain untouched until explicit recovery; offline records never disappear. Parent-to-child/child-to-parent/link-to-mount transformations require restore, validate, then new migration; no automatic split/merge. Insufficient local space preserves old layout. Restoration into an external ancestor is not restoration to local disk.

Remove automatic chmod0700 fallback on first mount error. Make preparation permissions checked and identity-aware; reject any local content including name-only DS_Store exemptions; verify underlying content after mount and surface conflicts without automatically detaching active data. Temporary unavailability retries; terminal policy/path/permission intervention does not. New dedicated volumes use and verify owners on each mount; do not enable global ownership database or remount real active legacy volumes automatically.

## Task 5: Verification and review

Test-first behavior changes. Exhaust high-risk finite matrices: exact protected paths/descendants; all low-level entrypoints with spoofed flags; old parent/new child and inverse; classic on/off; managed states online/offline/missing/unreadable; load order; same-path/ancestor/descendant/sibling relations among mount/link/transaction/retained entries; aliases, similar prefixes, foreign UUID, same-name replacement, changed inode, source/destination/backup nested mounts.

Cover both toggles' four combinations and WeChat whitelist invariance; root and child metadata, target inherited ACL, hardlinks, relative links; same-size writes with restored mtime, new/delete/rename, held fd append, WAL commits, writes before/after copy/verification/switch/cleanup; copy/record/mount/rename/unmount/delete failures. Inject interruptions before/after each dangerous stage and reopen/reenter twice for idempotence. Expectations must be hand-derived and assert actual state, content, identity and commands, not source text or mocks alone.

Run existing full test suite, new deterministic matrix, and actual production API closed loops on owned APFS images (migrate, retain, offline, remount, restore, explicit cleanup), legacy recovery and real nested mounts. Use strict UUID/image guards; preserve logs and clean owned artifacts. Validate actual statfs, UUID, hashes/metadata and persisted state. Use synthetic sandbox probe only, not user applications. Review code independently; fix meaningful findings before finishing.

Minimum macOS 12 and latest supported OS/architectures require actual evidence for release; unavailable platforms are NOT passed and must be listed as release blockers, without secretly reducing support. No claim of newly verified WeChat business paths. Do not publish/merge/deploy automatically. Commit reviewable changes in the worktree and provide test/decision/remaining-platform evidence.
