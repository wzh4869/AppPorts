# Upgrading to macOS 27

{% hint style="success" %}
**The key point**

If an app such as WeChat stopped opening from Finder or the Dock after you agreed to re-sign it in an older or test version of AppPorts, follow the repair steps below. Restore old container links first, then restore the original app or reinstall from an official source. **Keep the data directories and do not re-sign again.** A signature error alone does not mean your data is damaged.
{% endhint %}

## Repair <a href="#repair" id="repair"></a>

Click **Repair** directly in the app’s row, or choose “Show repair steps” from its context menu. Terminal commands are not required. This guide describes the current development version; the manual steps also apply if your version has no repair panel. Connect the original external drive, quit the affected app completely, and keep your data and backups.

{% hint style="success" %}
**Automatic re-signing at login**

The current development version disables automatic re-signing at login on macOS 27 or later and stops and removes the old login task. If cleanup is incomplete, retry in Settings.

**Update and open AppPorts once before upgrading macOS** so the installed background task receives the version check. Downloading the new version without opening it does not update the old task.
{% endhint %}

### 1. Restore container data migrated through old links <a href="#_1-restore-container-data-migrated-through-old-links" id="_1-restore-container-data-migrated-through-old-links"></a>

If the panel finds container directories linked to the external drive, click “Restore all”. Otherwise skip this step. The manual route is Data Directories → App Data → select the app → restore the linked container directories. Directories already using APFS mount migration do not need restoration just to repair a signature.

### 2. Restore the original app or reinstall officially <a href="#_2-restore-the-original-app-or-reinstall-officially" id="_2-restore-the-original-app-or-reinstall-officially"></a>

- **Full original-app backup available:** use “Restore Original Signature”. This restores the backed-up app version and its signature, including when the real app is on the external drive. Moving it back first is unnecessary. AppPorts checks that the current app matches the backup; an updated or changed app requires a matching official original.
- **Only a legacy identity record:** supply an official original `.app` of the same version, or reinstall from the App Store or developer’s website. An identity name alone cannot recreate a developer signature.
- **Installing over an app on the external drive:** first use “Move back” so the installer replaces the real local app rather than just its launcher.

**Do not remove the container data directories.** Keep a separate backup of important data. Continued access to chat history and login sessions also depends on app versions, permissions, and the data itself. See [Signature Backups and Restoration](datamigrae/resign.md#signature-backups-and-restoration).

### 3. Check again and open from Finder or the Dock <a href="#_3-check-again-and-open-from-finder-or-the-dock" id="_3-check-again-and-open-from-finder-or-the-dock"></a>

Click “Check again”, then open the app from Finder or the Dock and confirm that its data is accessible. “Signature check unavailable” is not a confirmed replacement or a successful repair; reconnect the drive and retry. Scanning preserves recovery backups. An app that still opens can be handled later, but opening successfully does not prove its original signature has been restored.

### 4. Optional: continue migrating the data <a href="#_4-optional-continue-migrating-the-data" id="_4-optional-continue-migrating-the-data"></a>

After repair, select the data in App Data and click “Migrate”. AppPorts checks the destination and uses [APFS mount migration](datamigrae/mount-migration.md) for container data, preserving the app’s signature. The current method requires an **unencrypted APFS external drive**. You can choose another drive or leave the data on this Mac. Allow removable-volume access if macOS requests it, and connect the drive before using the app. See [APFS preparation](why-apfs.md#what-to-do).

## Who Is Affected? <a href="#who-is-affected" id="who-is-affected"></a>

| Item | Description |
|------|-------------|
| Trigger | Upgrading to macOS 27 |
| Affected apps | Apps whose `~/Library/Containers/` or `~/Library/Group Containers/` data was migrated and which were re-signed Ad-hoc; or sandboxed apps manually re-signed from the right-click menu |
| Typical symptom | Opening from Finder / Dock does nothing, or the icon appears briefly and disappears without an error dialog. Not all re-signed apps behave this way: QQ Music runs normally on the same Mac with 27 |
| Data | A signature error alone does not establish data corruption; preserve the original data and backups |
| Confirmed case | WeChat 4.1.15, macOS 27.0 (26A428) |

Re-signing removes the app's sandbox identity. When macOS 27 checks whether the app is entitled to access its container, existing permission records for its original signature may no longer match. WeChat's logs show `Failed to match existing code requirement`. Apps without an old record, such as QQ Music, are currently allowed through, but lost entitlements such as Keychain login access are not restored. See [Container Data, Sandboxing, and Signing Identity](datamigrae/container-identity.md).

AppPorts reports a replaced signature only when a backup records an original developer identity and the real app is now confirmed Ad-hoc. A timeout or unreadable external app needs another check. An app that was originally Ad-hoc, a migrated app, or a local launcher does not by itself justify re-signing.

## What Does Not Fix It <a href="#what-does-not-fix-it" id="what-does-not-fix-it"></a>

| Action | Why It Does Not Help |
|--------|----------------------|
| Restoring the data locally and assuming the repair is complete | Restoration fixes access to external data, not the signature. The re-signed app may still quit immediately |
| Clicking "Resign This App" again | Re-signing caused the problem and simply removes the entitlements again |
| Adding the app to Full Disk Access | May bypass the container check, but Keychain entitlements are still missing and login sessions may remain broken. This is only a temporary workaround |
| Treating a successful Terminal launch as a repair | Launching from Terminal borrows Terminal's permissions. Test by opening from Finder / Dock |

## Before Upgrading: Check First <a href="#before-upgrading-check-first" id="before-upgrading-check-first"></a>

Start with the “Signature replaced” indicators in AppPorts and follow [Repair](#repair). No warning is not a guarantee of macOS 27 compatibility. The optional script only checks accessible paths stored in old backups; moved apps, offline drives, and launcher paths can make it incomplete.

<details>
<summary>Optional technical checks</summary>

```bash
BACKUP_DIR="$HOME/Library/Application Support/AppPorts/signature-backups"
for plist in "$BACKUP_DIR"/*.plist; do
  [ -f "$plist" ] || continue
  original=$(/usr/libexec/PlistBuddy -c "Print :signingIdentity" "$plist" 2>/dev/null)
  app=$(/usr/libexec/PlistBuddy -c "Print :originalPath" "$plist" 2>/dev/null)
  case "$original" in ""|ad-hoc) continue ;; esac
  [ -d "$app" ] || continue
  if codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
    printf "%s\n    %s\n" "$app" "$original"
  fi
done
```

</details>

## After Upgrading: Confirm the Symptoms <a href="#after-upgrading-confirm-the-symptoms" id="after-upgrading-confirm-the-symptoms"></a>

Open the app from Finder or the Dock first. If it fails and AppPorts confirms a replaced signature, follow [Repair](#repair). Otherwise also check app compatibility, permissions, and the external drive.

<details>
<summary>Optional technical checks</summary>

Replace the example with the **real app’s path**, not its local launcher. These commands only read information. Ad-hoc must be compared with the original signing record; an access-denied log is a clue, not proof of the cause.

```bash
codesign -dv --verbose=4 "/Applications/WeChat.app" 2>&1 | grep -E "Authority|TeamIdentifier|Signature"
log show --last 1m --style compact 2>/dev/null | grep -i "rejected approval request"
```

</details>

## What AppPorts 1.9.0 Changes <a href="#what-appports-1-9-0-changes" id="what-appports-1-9-0-changes"></a>

These behaviors describe the current development version:

- Default mode uses APFS mount migration for container data and refuses sandbox-app re-signing.
- Full backups restore the original application. Legacy records require a matching official app.
- Confirmed signature replacements and unavailable checks are shown separately; recovery materials are retained.
- [Classic data migration mode](settings.md#classic-data-migration-mode) remains off by default. Updating AppPorts does not restore an already replaced signature automatically.

## Common Questions <a href="#common-questions" id="common-questions"></a>

### Will I Lose Chat History? <a href="#will-i-lose-chat-history" id="will-i-lose-chat-history"></a>

A signature error does not itself mean chat history is damaged. Keep the container directories, external data, and backups. Avoid uninstallers that erase app data. Verify access after repair; some login permissions may need to be established again.

### I Restored the Data, but the App Still Will Not Open <a href="#i-restored-the-data-but-the-app-still-will-not-open" id="i-restored-the-data-but-the-app-still-will-not-open"></a>

Restoring paths does not restore the developer signature. Restore the original app from a full backup or reinstall officially, then check again. If a properly signed app still fails, investigate its version and permissions.

### Does This Affect Only WeChat? <a href="#does-this-affect-only-wechat" id="does-this-affect-only-wechat"></a>

No. Existing tests show different behavior across apps. The warning identifies a risk to check, not a prediction that every app will fail.

### Did AppPorts Corrupt the Data? <a href="#did-appports-corrupt-the-data" id="did-appports-corrupt-the-data"></a>

The observed launch failures relate to the earlier re-signing method, not evidence of data corruption. Preserve the original data when investigating other problems. Default APFS container migration preserves application signatures.

## Related Documentation <a href="#related-documentation" id="related-documentation"></a>

- [Container Data, Sandboxing, and Signing Identity](datamigrae/container-identity.md): the underlying mechanism
- [Mount Migration](datamigrae/mount-migration.md): the new approach
- [Why External Drives Must Use APFS](why-apfs.md)
- [Re-signing and Crash Prevention](datamigrae/resign.md)
