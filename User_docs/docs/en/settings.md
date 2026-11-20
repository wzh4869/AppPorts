# Settings and permissions

Open Settings in the main window using the gear at the bottom of the sidebar (or press `Command + ,`). When permissions are not ready, a red (denied) or orange (unable to confirm) dot appears on both the settings gear and the Check button under Readiness. Check Readiness and follow the permission and storage prompts before migrating; available items can differ between macOS versions.

## Application info and in-app updates {#updates}

The top-right card in Settings displays the running AppPorts version, its actual bundle path (selectable for copying), Check for Updates, Website, Docs and About.

When Check for Updates finds a new release, you can choose:

- **Update via China mirror:** download the update package from the domestic mirror without depending on GitHub connectivity.
- **Update via GitHub:** download the corresponding GitHub Release asset.

Progress is shown during download and can be cancelled. After verifying file size, SHA-256, code-signing identity, version, architecture and system requirements, click Install and Restart to replace and relaunch AppPorts. If migrations or other operations are still running, AppPorts asks you to finish them first; Application update guardian is safely suspended while AppPorts updates itself and resumed once the update completes or is cancelled. In-app installation requires AppPorts to reside in a writable local folder such as Applications; if an error occurs, a fallback download link opens in your browser.

After manually replacing AppPorts from a DMG or ZIP, open the new version once so it can synchronize the background agents and retire any old update guardian that is still running. If an agent still reports a problem, check **Background Agents** and retry there.

## Readiness and system permissions {#permissions}

Readiness is embedded directly in the top-right card. Click Check beside its heading to refresh permissions, external storage and App Store external-installation status. Ready items appear as compact status rows (hover for details) without redundant buttons; items needing attention keep their explanation and Open System Settings button.

| Item | Purpose | What to do |
| --- | --- | --- |
| Full Disk Access | Let AppPorts read and manage protected data locations. | Click Open System Settings, grant access and reopen AppPorts when prompted; if AppPorts is not in the list, drag its icon from the floating guide directly into System Settings. |
| App Management | Allow modifying or managing other app bundles when macOS requires it. | System preflight reports Ready, Permission needed or Unable to confirm. When not ready, Open System Settings opens the App Management page directly and shows the same drag-and-drop icon guide. |
| Removable Volumes | Let the moved app access external data. | The original app may ask separately on first access; this is distinct from AppPorts' permissions. |
| External storage | Check connection, format and encryption. | Choose a suitable destination using the [storage guide](/docs/storage-guide). |

Before starting new migrations, creating/opening/remounting an app library image, or opening permission guides, AppPorts checks that it is located in Applications; browsing lists, scanning apps and restoring existing data back to the Mac are not blocked by this check. Granting access to AppPorts does not authorize other apps; for missing data, first check [mount state and the original app's permissions](/docs/faq#missing-data).

If **App Management** or **Full Disk Access** is already enabled in System Settings after an upgrade but AppPorts still reports it missing, macOS may be using a permission record tied to the previous signing certificate. If you see **System Permissions Need to Be Granted Again**, follow the prompt to open the relevant settings, add the new AppPorts, and turn on its switch. If the old entry still does not work, click **Clear Legacy Permission Records** in **Readiness**, then return to System Settings to add AppPorts and switch it on again. Clearing **Full Disk Access** may require administrator confirmation. If clearing fails, select the old entry in System Settings, remove it with `-`, and add AppPorts again. Reopen AppPorts as prompted and check its status in **Readiness**.

## App Store and non-native apps {#app-store}

On macOS 15.1 and later, Settings displays App Store App External Installation and checks read-only whether the App Store's preferred external disk matches the external drive selected in AppPorts:

- When matched, it shows Configured along with the destination `Applications` folder; when not configured or set to a different disk, it provides Open App Store Settings.
- The App Store itself uses that setting only for newly downloaded apps larger than 1 GB and manages their updates; **AppPorts is not limited by the 1 GB threshold and can migrate App Store apps of any size, including apps under 1 GB, into that folder**.
- If external installation is not yet configured when you select or restore external storage, the main window displays a prompt. Choosing Don’t remind me again (or pressing Esc) remembers your choice permanently while keeping the configuration entry available here in Settings. I've Set It Up re-reads the real system preference rather than creating an empty folder to fake completion.

Earlier systems show Allow Migration of Mac App Store Apps and Allow Migration of Non-Native Apps. Read the prompts before enabling them: system support, updates and device requirements still apply. See [application migration](/docs/core#updates).

## Classic data migration mode {#classic-data-migration-mode}

Classic data migration mode (not recommended) is off by default and retained for users who still need to handle legacy container links. Enabling it requires risk confirmation. Disabling it does not restore data or changed signatures.

Migration and re-signing are separate. This switch does not reinstate automatic re-signing. See [classic mode](/docs/classic-mode) for scope and transition steps, and the [historical archive](/docs/archive/data-signing) for old behavior.

## Manual signing and repair {#manual-signing}

Signing changes application identity; it does not move files to another location. Use manual re-signing only when you understand its purpose. Sandboxed apps are restricted by default; classic mode still requires confirmation for the current operation.

Once the app list confirms that an app is re-signed, its context menu keeps Restore Original Signature and hides Resign This App. Eligible apps show the re-sign action again after returning to an official state. If inspection is inconclusive, use Check Signature first rather than treating menu visibility as a health check.

Restore Original Signature requires a suitable, verified original app. Do not force a different version into place. For Signature replaced, start with the repair panel. Without a usable backup, follow the instructions for an official original. Full steps are in [upgrades and repair](/docs/macos-27#repair).

### Where originals are saved {#signature-backups}

Starting with 1.9.1 build 31, when you manually re-sign an officially signed app, AppPorts retains its verified complete original in a **visible `AppPorts Backups` folder at an external volume's root**, with a bilingual `README.txt`. No additional location picker or backup-management page is needed; inspect it directly in Finder.

AppPorts tries the app's own external volume first, then the current external library's volume, then other suitable external volumes, preferring more free space. A destination must be a connected, writable, local physical external drive with enough capacity. Internal drives, network volumes and disk images are excluded. Without a suitable drive, the operation stops before changing the installed app.

**Even an app installed internally needs an external drive for its original.** Only small indexes and operation records remain internally long-term; re-signing still needs temporary workspace. On the same volume, the original can move directly into the backup folder. Across volumes, AppPorts copies and verifies durable external storage before removing the internal temporary original.

These originals restore app contents and the official signature. **They do not contain messages, documents or other application data.** They are not an independent disaster-recovery backup: a drive failure can affect both the app and its original if they share that drive.

### Restore and clean up originals {#signature-backup-cleanup}

Connect the drive holding the original, then choose Restore Original Signature for the installed app in AppPorts. It checks version, content, developer identity and related data dependencies. Re-signing the same version again retains the first official original rather than replacing it with a re-signed copy.

AppPorts keeps originals that still have recovery value. It automatically removes redundant originals only after verifying an official restored state or an authenticated newer official version from the same developer, and excluding pending operations and data dependencies. Useful complete originals saved internally by older versions move externally when conditions permit; the internal copy is removed after successful verification.

If you no longer need an original, you can delete that package in Finder. This does not remove the installed app or personal data, but loses the offline recovery capability provided by that copy. An official reinstall may then be needed. Trash still occupies space, and shared APFS blocks mean displayed size is not the amount you will necessarily recover.

Keep the folder in place, do not modify originals, and do not launch them as everyday apps. An offline drive does not mean an original has become invalid. Resolve pending operations through AppPorts before cleanup. For identity-only records, see [historical signature backups](/docs/archive/data-signing#backups).

### Old login tasks {#login-signing}

Automatic re-signing at login is disabled on every macOS version; build 31 also removes its settings card. Open AppPorts once after updating so it can handle old login tasks. Only failed cleanup displays “The old login re-signing task has not been fully disabled. Please retry.” Use Retry and keep the error details.

## Background agents {#mount-agent}

The Background agents card provides two login background services that are enabled by default and can be turned off independently:

- **Disk maintenance agent:** at login, when an external drive reconnects, or during scheduled checks for a selected image, restores migrated container data volumes and the selected [APFS app library image](/docs/storage-guide#app-library-image), and keeps AppPorts-managed APFS data volumes hidden. Turning it off unloads its automatic configuration while preserving current mounts, data and recovery records; manual foreground mounting and recovery remain available.
- **Application update guardian:** keeps watching migrated apps after AppPorts quits, attempts signature-verified installation from complete cached builds when an eligible ShipIt update fails, and reports results in Task Center (offering Roll Back Update on failure). Turning it off safely stops automatic recovery while preserving existing receipts and copies. It currently covers only eligible ShipIt updates, never re-signs apps, and does not cover every other updater framework.

Both agents run windowless modes of the AppPorts bundle installed in Applications without blocking normal reopening of the main window, and neither guarantees completion before every login app starts. Open AppPorts once after moving or updating it so agent configurations are verified and synchronized; if a background item was disabled or synchronization reports an error, use Retry on the card. [Restore managed container data](/docs/restore#data) before removing AppPorts.

## Log settings {#logs}

Use the Log Settings card to enable or disable logging, adjust maximum log size (1 MB to 100 MB), reveal logs in Finder, export a diagnostic package or clear logs (Logs → Export Diagnostic Package in the menu bar also works). Export does not send the package automatically.

Inspect the contents before sharing, and include macOS and AppPorts versions, the action you took and the displayed message. See [reporting a problem](/docs/faq#feedback) and the [privacy policy](/docs/privacy).

## Task history {#task-history}

Clear the completed task list on quit under Task Center is enabled by default. Disable it to keep successful tasks (including completed background update-guardian tasks) in display history. Clear Completed and row removal in Task Center likewise affect display only: they do not delete apps, data, migration records or update receipts needed for recovery.

Active migration tasks placed in the background still require the main AppPorts app to remain running. On reopening, inspect records for unfinished migrations; history does not automatically repeat migration. See [Task Center](/docs/datamigrae/operation#task-center) and [recovery](/docs/restore#recovery) for pause, cancellation and issue handling.
