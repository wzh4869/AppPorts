# Troubleshooting

## An App Does Nothing When Opened, or Its Icon Disappears Immediately <a href="#an-app-does-nothing-when-opened-or-its-icon-disappears-immediately" id="an-app-does-nothing-when-opened-or-its-icon-disappears-immediately"></a>

The most common cause is an app previously re-signed by AppPorts being denied access to its own container after upgrading to macOS 27. This does not affect every re-signed app; WeChat is confirmed. The data is intact.

To confirm:

```bash
codesign -dv --verbose=4 /Applications/<应用名>.app 2>&1 | grep -E "Signature|TeamIdentifier"
# 出现 Signature=adhoc 和 TeamIdentifier=not set 即是
```

Repair in this order: restore container data → reinstall from an official source → use mount migration if needed. **Do not** re-sign again or assume restoring data alone completes the repair. See [Upgrading to macOS 27](macos-27.md#repair).

## Mount Migration Fails <a href="#mount-migration-fails" id="mount-migration-fails"></a>

| Message | Cause | What to Do |
|---------|-------|------------|
| External storage is not APFS | The drive uses exFAT / NTFS / HFS+ | Keep container data on this Mac and migrate other data normally. When ready, use an APFS drive or follow [Prepare an APFS External Drive](why-apfs.md#prepare-apfs). Built-in tools cannot directly shrink exFAT |
| External storage is encrypted | The drive uses encrypted APFS; a new data volume does not inherit its password | Keep things as they are, or select unencrypted APFS. See [Encrypted External Drives](why-apfs.md#encrypted-drives) |
| Insufficient space | Not enough space on the external drive for migration or on this Mac for restoration | Free space and retry. This check happens before creating a volume or copying; no data has been changed |
| Disk command failed … `kDAReturnNotPrivileged` | Older systems such as macOS 12 do not let ordinary users mount at custom paths | AppPorts retries with an administrator password prompt. Enter the password. Versions before 1.9.0 did not have this step |
| Administrator authorization cancelled | The password prompt was cancelled | Run the operation again |
| Mount point is not empty | The app wrote local files while the volume was unmounted | Move those files elsewhere, then click "Mount" |
| Post-mount verification failed | The volume mounted at an unexpected path | Export a diagnostic package and submit an Issue |
| External volume not found | The drive is disconnected or the volume was deleted | Connect the drive and refresh. If the volume was deleted, its data cannot be recovered from it |

AppPorts rolls back a failed migration by deleting the new volume and restoring the original directory. In Disk Utility, check for leftover volumes beginning with `AppPorts-`.

## App Cannot See Data After Mount Migration <a href="#app-cannot-see-data-after-mount-migration" id="app-cannot-see-data-after-mount-migration"></a>

Check in this order:

1. **Is the external drive connected and the volume mounted?** The directory in App Data should be "Mounted". For "Awaiting mount", click "Mount". For "Drive Not Connected", connect the drive.
2. **Did you deny the permission prompt?** In System Settings → Privacy & Security → Files and Folders, find the app and enable Removable Volumes. Or run `tccutil reset SystemPolicyRemovableVolumes <Bundle ID>` in Terminal to ask again next time.
3. **Is it a built-in system app?** Apps under `/System/Applications` are silently denied without a prompt. AppPorts does not support migrating their data.
4. Check the system log:

   ```bash
   log show --last 2m --style compact 2>/dev/null | grep -E "deny\(1\)|RemovableVolumes"
   ```

   `kTCCServiceSystemPolicyRemovableVolumes` indicates the permission issue in step 2.

## App Will Not Start After Migration <a href="#app-will-not-start-after-migration" id="app-will-not-start-after-migration"></a>

1. Confirm the external drive is connected.
2. Check its badge. "Orphan Link" means the external app is missing and its local link needs removal.
3. If macOS says it is "damaged", try reinstalling first. If needed, consider "Resign This App" in the right-click menu. Sandboxed apps are refused; see [Re-signing and Crash Prevention](datamigrae/resign.md).
4. An app locked with `uchg` may be unable to self-update. This is expected.
5. Open the logs in Finder from the menu bar and look for relevant errors.
6. Move the app back from the external library to check whether external storage is the cause.

## Signature Restoration Fails <a href="#signature-restoration-fails" id="signature-restoration-fails"></a>

| Cause | What to Do |
|-------|------------|
| Backup file is missing | No restoration record is available. Reinstall from an official source. A record may also have been cleaned up, so its absence does not prove the app was never re-signed |
| Legacy backup does not contain the original app | Select an official original `.app` of the same version or reinstall. New full backups do not need the developer's private key |
| App was updated or backup verification failed | Keep the current app and backup; stop replacement. Select a matching official original or reinstall |
| System protection prevents replacing the app | Preserve the current app and backup; reinstall through the App Store or official installer |
| App is owned by root | An administrator password prompt changes ownership. Cancelling makes the operation fail |
| App is sandboxed | Re-signing is refused by default. If re-signed in classic mode, restore container data before restoring the original signature |

## Migration Is Interrupted <a href="#migration-is-interrupted" id="migration-is-interrupted"></a>

If the external drive disconnects, the system crashes, or AppPorts is force-quit:

- **Symbolic-link migration**: reopen AppPorts. It checks `.appports-link-metadata.plist` in the external directory and resumes only when it fully matches; otherwise it stops for you to review. Look for "Needs Normalization" or "Awaiting Relink".
- **Mount migration**: failures during the operation roll back automatically. If AppPorts itself was force-quit, reopen it and inspect the original directory. If it is still present, the data is safe and an extra `AppPorts-` volume can be removed in Disk Utility. If the directory was renamed to `.appports-migration-backup-*`, rename it back.

## External Storage Is Offline <a href="#external-storage-is-offline" id="external-storage-is-offline"></a>

- Symbolic-link directories: the link points to an unavailable path, so the app cannot read the data.
- Mount-migrated directories: appear empty, and the app does not write local data.
- App bundles: the local launcher cannot open the external app, but the launcher itself does not crash.

After reconnection, AppPorts rescans and remounts migrated volumes automatically. Older systems require an administrator password once.

## App Store Apps Cannot Be Migrated to External Storage <a href="#app-store-apps-cannot-be-migrated-to-external-storage" id="app-store-apps-cannot-be-migrated-to-external-storage"></a>

**Before macOS 15.1**: native external installation is unsupported. Enable App Store app migration in AppPorts Settings and migrate manually. Repeat after updates.

**macOS 15.1 and later**: enable "Download and install large apps to a separate disk" in App Store settings and select the same drive as AppPorts.

## Migration Reports an Existing Destination <a href="#migration-reports-an-existing-destination" id="migration-reports-an-existing-destination"></a>

- **Apps**: AppPorts stops if the external destination is neither the old copy associated with "Pending Move Out" nor a recognized old AppPorts entry. Inspect it in Finder before deciding what to do.
- **Data directories**: an external directory without a matching AppPorts marker is not taken over or overwritten based on similar size. Check its contents and handle it manually.
- **Moving back locally**: a real local app with the same name, or a link belonging to another external app, is not overwritten.

## The Data Directory List Looks Wrong <a href="#the-data-directory-list-looks-wrong" id="the-data-directory-list-looks-wrong"></a>

1. AppPorts watches file-system changes and usually refreshes automatically.
2. When switching apps quickly, old results do not overwrite the current selection. Wait for scanning if the list briefly appears empty.
3. If it does not refresh, click Refresh at the top.
4. For persistent problems, check scanning errors in the logs.
