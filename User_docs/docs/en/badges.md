# Badges and status

Badges show the current state of an app or directory. The combination of badges varies by item.

## App location and update protection {#apps}

Badges appear below the app name in both the local and external app lists. When an app has an update status badge, it appears first. Click **Available** to see how to update the app, or **Unknown** to see why AppPorts cannot confirm an update method. Badges and their explanations use your selected AppPorts language in all 22 supported languages.

Resting the pointer on a clickable badge for about 0.25 seconds opens the same content as a click; moving past it sooner cancels the preview. You can move the pointer into an explanation to keep reading. The preview closes when the pointer leaves both the badge and the explanation. Hovering over a task badge opens its details, and hovering over **Signature replaced** opens the repair panel, where you choose whether to start a repair.

| Badge | Meaning | What to do |
| --- | --- | --- |
| Linked | A local entry points to the external app (including unlocked ordinary apps and apps such as NetEase Music and WorkBuddy handled as ordinary migrations). | Connect the external drive to use it. |
| Locked Migration | The app is linked and its external bundle currently has update protection enabled. | Read [app updates](/docs/core#updates); move it back locally before updating if needed. |
| Unlocked Migration | A linked self-updating app whose external bundle is left unlocked. When the update guardian is on and the app shows **Available**, the list omits the **Unlocked Migration** badge. | Click for details; in-app updates can be attempted, and Application update guardian in Settings can assist with eligible update failures. |
| Partially Linked | Only some apps or components in a folder are linked. | Expand the folder and check each item. |
| Orphaned Link | The local entry exists, but its external target cannot currently be found. | Connect the original drive (or remount the app library image) and refresh. This does not prove the files were deleted. |
| Unlinked, External | The external app has no usable local entry yet. | Use “Link Back to Local” if needed. |
| Custom | AppPorts uses its own updater. | Keep AppPorts in the Applications folder on this Mac. |
| Available | The app has a confirmed update method after migration. | Click to see whether to update in the app, use the App Store, or update locally and move the new version out again. |
| Checking | AppPorts is checking whether the update guardian is ready. | The badge changes to Available automatically when the guardian is ready. |
| Unknown | AppPorts cannot confirm how this app will update after migration. | You can still try updating. Click the badge to check whether the guardian is off. |
| Pending Move Out | A real local app appears newer than the external copy. | Check both versions and the destination, then move the newer local app out. |

[![The Mac Local Apps list in an earlier AppPorts build (Simplified Chinese interface). Thunderbird is local and TPH is linked. Trae CN also has a pending signature check that you can run from its row.](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-apps-live-panel-936ddc72877c892e.png?sign=337FzYmLfLNxE05XeK_eS8pW4fZP8Ir-IsHrdZn9PIs%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-apps-live-panel-936ddc72877c892e.png?sign=337FzYmLfLNxE05XeK_eS8pW4fZP8Ir-IsHrdZn9PIs%3D%3A0)

*The Mac Local Apps list in an earlier AppPorts build (Simplified Chinese interface). Thunderbird is local and TPH is linked. Trae CN also has a pending signature check that you can run from its row.*

AppPorts recommends keeping Clash Verge, Visual Studio Code (including Insiders), Xcode, and Claude desktop on your Mac. Their rows omit the update badge. If you choose to move them, AppPorts explains the risks.

“Locked Migration” protects specific update scenarios; it does not replace a backup, and upgrading AppPorts does not automatically unlock previously locked apps. “Pending Move Out” is not an instruction that must be acted on immediately.

## App types {#types}

| Badge | Meaning and limitations |
| --- | --- |
| Running | Save your work and quit the app before migrating or restoring it. |
| System | A macOS system app, generally unsuitable for migration. |
| Non-native | An iPhone or iPad app running on Mac. Support depends on the device and OS. |
| App Store | The app comes from the Mac App Store. |

Apps verified to update independently show Available with the guardian off. Examples include IINA with Sparkle and Qoder with ShipIt. Other apps with only the same framework identified show Unknown when the guardian is off. App Store copies follow the store’s external installation settings. Detecting Electron alone gives an Unknown badge.

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
