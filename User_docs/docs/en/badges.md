# Badges and status

Badges describe an item's current state; they are not a complete health check. Read the label before deciding what to do. Clickable badges provide more detail, and different versions may show different combinations.

## App location and update protection {#apps}

| Badge | Meaning | What to do |
| --- | --- | --- |
| Local | The app is on your Mac and has no other label to display. | Migrate it when you want to free space. |
| Linked | A local entry points to the external app (including unlocked ordinary apps and apps such as NetEase Music and WorkBuddy handled as ordinary migrations). | Connect the external drive to use it. |
| Locked Migration | The app is linked and its external bundle currently has update protection enabled. | Read [app updates](/docs/core#updates); move it back locally before updating if needed. |
| Unlocked Migration | A linked self-updating app whose external bundle is left unlocked. | Click for details; in-app updates can be attempted, and Application update guardian in Settings can assist with eligible update failures. |
| Partially Linked | Only some apps or components in a folder are linked. | Expand the folder and check each item. |
| Orphaned Link | The local entry exists, but its external target cannot currently be found. | Connect the original drive (or remount the app library image) and refresh. This does not prove the files were deleted. |
| Unlinked, External | The external app has no usable local entry yet. | Use “Link Back to Local” if needed. |
| Pending Move Out | A real local app appears newer than the external copy. | Check both versions and the destination, then move the newer local app out. |

[![The Mac Local Apps list in AppPorts (Simplified Chinese interface). Thunderbird is local and TPH is linked. Trae CN also has a pending signature check that you can run from its row.](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-apps-live-panel-936ddc72877c892e.png?sign=337FzYmLfLNxE05XeK_eS8pW4fZP8Ir-IsHrdZn9PIs%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-apps-live-panel-936ddc72877c892e.png?sign=337FzYmLfLNxE05XeK_eS8pW4fZP8Ir-IsHrdZn9PIs%3D%3A0)

*The Mac Local Apps list in AppPorts (Simplified Chinese interface). Thunderbird is local and TPH is linked. Trae CN also has a pending signature check that you can run from its row.*

“Locked Migration” protects specific update scenarios; it does not replace a backup, and upgrading AppPorts does not automatically unlock previously locked apps. “Pending Move Out” is not an instruction that must be acted on immediately.

## App types {#types}

| Badge | Meaning and limitations |
| --- | --- |
| Running | Save your work and quit the app before migrating or restoring it. |
| System | A macOS system app, generally unsuitable for migration. |
| Non-native | An iPhone or iPad app running on Mac. Support depends on the device and OS. |
| App Store | An app from the App Store, or an external installation in the drive's `Applications` folder managed by macOS. Click for details where available. |

The `Sparkle` and `Electron` framework badges shown in earlier versions have been removed from app and app-data lists; self-update handling is represented directly by migration confirmation and the Locked / Unlocked Migration badges.

## Signature status {#signing}

| Badge | Meaning | Recommendation |
| --- | --- | --- |
| Signature replaced | The original developer signature was replaced by a local signature. | Open “Repair” or “View repair steps” and follow [upgrade and repair](/docs/macos-27). |
| Signature check pending | The signature or recovery-material check did not produce a reliable result. | Connect the drive, use “Check signature,” and keep your backups. Provide diagnostics if this persists. |
| Resigned | The app is identified as locally re-signed, without the more specific developer-signature replacement warning above. | This does not mean the official identity is restored or that container data is accessible. |

Signature status and data location are separate. “Mounted” does not establish that an app's signature is healthy, and “Signature replaced” does not establish that data is damaged.

For an app confirmed as re-signed, the context menu retains “Restore Original Signature” and hides the duplicate re-sign action. Check the signature first if its status is unclear. Newly saved official originals are on an external drive; reconnect that drive before restoring. See [signing and repair](/docs/settings#manual-signing).

## Data directories and custom folders {#data}

| Status | Meaning | What to do |
| --- | --- | --- |
| Local | Data is still on this Mac. | Check its purpose before migrating. |
| Linked | A symbolic link at the original path accesses external data. | Keep the drive connected. |
| Mounted | The external data volume is attached at the original directory. | Open the app and verify actual reads and writes; resume automatic mounting if previously paused. |
| Awaiting Mount | The data volume was found but is not attached at its original path (or automatic mounting was paused by manual unmounting). | Use “Mount.” |
| External Drive Disconnected | The managed data volume cannot currently be found; the local directory remains a read-only empty folder for protection. | Connect the original drive and check that the volume is available; a readable empty folder does not mean data was lost. |
| Awaiting Relink | External data remains, but the local entry needs rebuilding. | Check the target, then use “Relink.” |
| Needs Normalization | A managed link was recognized, but its location needs tidying. | Read the confirmation for “Normalize.” For old container links, see [classic mode](/docs/classic-mode). |
| Existing Symlink | A symbolic link exists but is not yet managed in AppPorts' layout. | Open “Link Details” to inspect the real target, then adopt, restore or use “Force Unlink” as needed. |
| User folder shortcut | A container shortcut to Desktop, Downloads, Pictures, or another personal folder; the data is not exclusive to this app. | Target sizes are excluded and migration or restore is unavailable. Do not treat it as an ordinary empty folder. |
| Orphaned Link | A custom folder's link target is temporarily unreachable. | Check the drive, path, and connection first. |
| Not Found | The configured directory does not currently exist. | Check the original location before creating an empty folder with the same name. |
| External | A custom folder's data is stored externally. | Check the local side to decide whether relinking is needed. |
| Target Conflict | Other content already exists at the destination. | Establish which copy belongs where; do not overwrite it directly. |
| Copy Retained | An operation left a copy that must be retained or cleaned up later. | Follow the completion message after confirming where the valid data is. |

## Important, Recommended, and Optional {#priority}

These indicate a directory's importance, not the probability that migration will succeed. **Important** affects core app functionality; **Recommended** usually offers useful space savings; **Optional** may be small or reproducible. Quit related programs before migrating any category.

For example, “Recommended + Local” means a local directory may be worth reviewing. “Linked + Running” means the external app is in use. To change its location or repair an entry, see [restore, relink, and unlink](/docs/restore).
