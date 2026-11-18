# Classic mode

Classic Data Migration Mode retains the earlier way of handling container data with symbolic links. It is off by default and primarily helps users understand and handle existing migrations that still depend on the old method.

## What enabling it changes {#changes}

Eligible container items can offer legacy link migration and related link-management actions. Protected directories and conflicts are still checked; enabling the option does not make every directory movable.

In current builds, **migration and re-signing are separate actions**. Classic mode neither authorizes automatic re-signing nor restores the old “re-sign after migration” workflow. See [settings and permissions](/docs/settings#manual-signing) for manual signing and its restrictions.

## Why it is not the default {#why}

Container access is restricted by macOS. When a symbolic link points outside the container, the app may be unable to read the data. Re-signing to change the app's identity can also affect sandbox, keychain or app-group permissions. Some apps could no longer start normally in the tested macOS 27 environments.

This does not establish that every app fails, or that re-signing again fixes the problem. For eligible data, the default recommendation is [mount migration](/docs/datamigrae/baseinfo#mount), which preserves the real app's signature.

## Find and disable the setting {#settings}

Open Settings in the main window and look for Classic Data Migration Mode (Not Recommended). Read the confirmation before enabling it. Leave it off if you do not need legacy migration.

**Turning it off does not restore existing links or signatures changed earlier.** Handle existing data according to its actual state; the switch position alone does not establish that an upgrade is complete.

## If you already use the old method {#transition}

1. Connect the original drive, quit related apps and preserve current data and backups.
2. Restore container data moved using legacy symbolic links to its original location.
3. If the app's signature was replaced, follow [macOS 27 upgrades and repair](/docs/macos-27).
4. Verify the app and data, then choose mount migration if external storage is still needed.

Without suitable APFS storage, container data can remain local. Do not enable classic mode merely to bypass format requirements.

Related: [restoration](/docs/restore), [symbolic-link experiments](/docs/blog/why-mount-and-apfs#symlink-experiment), and the [classic-mode glossary entry](/docs/glossary#classic-mode).

Changes to earlier switches and automatic signing are preserved in the [historical archive](/docs/archive/data-signing).
