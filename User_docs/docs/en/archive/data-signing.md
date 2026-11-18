# Archived: legacy data links and automatic re-signing

::: warning Historical feature
This page documents older releases. Current builds separate migration from manual signing and disable automatic login re-signing on every OS version. For new operations, see [migrate data](/docs/datamigrae/operation); for recovery, see [upgrade and repair](/docs/macos-27).
:::

## Versions and status {#versions}

| Feature | Historical behavior | Current status |
| --- | --- | --- |
| Container migration by symbolic link | The main approach in 1.8.1 and earlier: move data externally and create a link at the original path. | Mount migration is the default; limited management of old links remains in classic mode. |
| Re-sign after migration | An old data-directory toolbar switch and container confirmation offered migration-only or re-signing flows. During 1.9.0, related flows remained only in classic mode. | Automatic chaining is disabled in 1.9.1 development builds. Migration performs no signing operation. |
| Automatic re-signing at login | A login task checked and re-signed apps using the records and policy of that release. 1.9.0 disabled it on macOS 27, with transitional behavior on older systems. | Disabled on all systems in 1.9.1 development builds, which attempt to disable and remove the old task. Build 31 removes the permanent settings card and shows a retry only if cleanup fails. |
| Identity-only signature backups | Stored an app identifier, path, identity name, and timestamp without a complete original app. | Insufficient to restore the original signature. Records with provenance value remain until cleanup conditions are verified. |
| Complete originals on internal storage | Later implementations stored official app originals internally to restore contents and signatures. | Build 31 saves new long-term originals externally. Useful older originals move out automatically when conditions permit; the internal copy is removed only after verification. |

## What the old workflow did {#flow}

Legacy link migration copied data to a managed external location, then replaced the original directory with a symbolic link. If re-signing was selected, data migration and ad-hoc signing ran in sequence. Signing had to apply to the real app, not its local launcher.

Automatic login re-signing used a separate background task named `com.shimoko.AppPorts.re-sign`. This was not the container-data remount task. Settings, script rules, and defaults changed over time; one historical implementation does not describe every old release.

Tool directories and ordinary custom folders still support link migration. Automatic signing was retired; symbolic-link functionality as a whole was not.

## Why this changed {#why}

Local re-signing changes app identity and may remove or alter sandbox, app-group, and Keychain entitlements. It cannot replace the original developer signature or guarantee restored container access. In the tested macOS 27 environment, some re-signed apps failed to start even with all data stored locally.

Signing and migration can also fail at different stages. Chaining them automatically makes it harder to tell whether data has moved or the app identity has changed. The current workflow separates them, with an independent signing operation when needed.

## Older backups and recovery material {#backups}

Old signature records are stored in AppPorts' `signature-backups` directory. An identity name alone cannot reconstruct an original app. Removing a signature or applying another ad-hoc signature never amounted to restoring the official signature.

Later complete backups include original app files and verification information. Recovery still checks app version, developer identity, and contents; an old backup cannot simply overwrite a newer app. Build 31 keeps this recovery capability while saving new long-term originals in the visible external `AppPorts Backups` folder. Useful older internal originals move automatically when a suitable drive is available and no pending operation depends on them. The internal original remains until the external copy passes verification.

Identity-only records and indexes whose originals are confirmed missing are not indiscriminately deleted. AppPorts cleans them up only when no unfinished operation depends on them and either reliable provenance survives elsewhere or the installed app has been verified as the corresponding official app. Small records remain when ownership is unclear or they are the only source of provenance.

An offline drive is different from a missing file. Age or a changed signature does not make a backup useless. Complete originals with recovery value remain. See [signature originals](/docs/settings#signature-backups) for current storage, recovery, and manual cleanup.

## What to do now {#transition}

Connect the original drive and quit the related apps. Restore old container-link data, then check whether the official app also needs restoring. Open AppPorts once after updating so it can clean up the old login task. Retry in Settings if it reports that the task is still enabled.

Turning classic mode off does not move data back or restore a signature. Once the old state is resolved, eligible data can use mount migration; ordinary directories can continue using link migration as needed.

Related: [classic mode](/docs/classic-mode) · [signature status](/docs/badges#signing) · [historical feature archive](/docs/archive/overview)
