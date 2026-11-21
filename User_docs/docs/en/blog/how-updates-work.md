# How AppPorts decides whether a migrated app can update

IINA can install a new version in place on an external drive. Another app may install its new version back on your Mac. The **Available** badge means AppPorts has identified a way to update the app after migration. To find out whether a new version is out today, use the app’s own update command or the App Store. Check for Updates in AppPorts Settings checks AppPorts itself.

The badge and migration examples use the November 21, 2026 AppPorts 2.3.1 candidate (build 82). On November 22, we also verified the guardian’s task history and log entries with build 84. You can check your build number in Settings.

## What Check for Updates checks {#appports}

AppPorts checks the official release feed when you open its main interface. You can also run a check in Settings. AppPorts compares each numeric component of the version in the official `latest.json` feed with the version you are running. For example, if both versions are 2.3.1, increasing the build number from 80 to 81 alone does not trigger an update prompt. A manual check reports a connection failure separately from a successful check that finds your version is current.

When a newer release is available, you can download that version from the China mirror or GitHub. AppPorts checks the package size, SHA-256 digest, app identifier, version, architecture, and minimum system requirement. Choosing **Install and Restart** starts the replacement. Let any active migration or recovery finish first. [Update settings](/docs/settings#updates)

## How to read Checking, Available, and Unknown {#badges}

The item in your Mac’s Applications folder may be a launcher. AppPorts follows it to the real app bundle, then checks its update components, location, and lock state. Click the update badge beneath the app name to see why AppPorts assigned that status. It appears first when present. In the development build with quick hover, resting the pointer on the badge for about 0.25 seconds opens the same explanation. [Badges and status](/docs/badges#apps)

| What AppPorts finds | What the list shows |
| --- | --- |
| Sparkle apps verified to update the external copy themselves | Direct-download versions of NetEase Music, IINA, Keka, CotEditor, Transmission, Mac Performance Monitor, and PortKiller show Available when both the app identifier and tested installer match. The guardian can be off. |
| ShipIt apps verified to complete their own installation | Qoder and OpenCode updated through their bundled ShipIt. When the helper matches, they show Available even with the guardian off. A ready guardian can also attempt recovery after an installation failure. |
| Other recognized Sparkle or Squirrel/ShipIt apps | AppPorts has only identified the framework or a recovery path. The badge shows Available when the guardian is ready, Checking while it starts, and Unknown when it is off. WorkBuddy has a confirmed migration, and DeepSeek Harness has a confirmed guardian recovery. |
| Electron alone, or a file with “updater” in its name | Unknown. Electron apps can use different installers, and this evidence does not establish where an update will land. |
| A Mac App Store app | On macOS 15.1 or later, a store receipt and a copy in the `Applications` folder on the drive configured in the App Store qualify as Available. A local store app can also qualify before migration to that destination. The App Store performs the update independently of the guardian. |
| Apps verified to update in place | Firefox, Thunderbird, Google Chrome, JetBrains Toolbox, Zed, DMG Canvas, Querious, and Screenflick for Mac show Available after an unlocked migration when their bundle identifier and bundled executable match. You can update them in the app with the guardian off. |
| Official Tauri updater | Open the app from Applications or its existing Dock icon, then update in the app as usual. AppPorts recognizes the plugin version in standard builds. For versions 2.10.0 through 2.13.1 the entry supplies a temporary directory on the app’s volume. Starting with 2.13.2, the 2.x plugin chooses its own location. Both work with the guardian off. |
| Another updater | An app can qualify once testing confirms it updates the external copy independently, or installs locally and can then be moved out again. Untested apps show Unknown. |

Older Tauri plugins need the local launch entry. AppPorts points an existing Dock pin to that entry and keeps its position. A second icon may briefly appear during launch. Opening the external copy directly skips this adjustment.

NetEase Music has a recorded successful update through its own Sparkle updater after unlocked migration. A maintainer confirmed WorkBuddy, which uses Squirrel/ShipIt. For DeepSeek Harness, a recovery test also confirmed that reopening the original local entry launched the updated external copy. The versions used in that test appear below.

## Choosing a mode and using Pending Move Out {#migration}

When a mode choice is needed for an Available app, **Migrate unlocked (recommended)** is the default action, and Return selects it. For a batch, every app that requires a choice must qualify before AppPorts recommends it. For Checking or Unknown, choose the mode yourself. NetEase Music and WorkBuddy follow the ordinary migration flow and skip the prompt.

An external copy that is already locked shows Locked Migration. Move it back locally, update, and move it out again. If an updater installs version 1.1 locally while 1.0 remains on the external drive, refreshing the list gives **Pending Move Out** priority. Check both versions and choose Move to External to move the new copy. A manual installation can produce the same version difference, so that observation alone does not give the app a lasting Available badge. [Updating and moving apps](/docs/core#updates)

## How the guardian handles a failed ShipIt installation {#guardian}

With Application update guardian enabled in Settings → Background agents, it can continue working after you quit the main app. Each third-party app still checks for and downloads its own updates. For a recorded migration, the guardian checks the following.

1. **Identify the installation attempt.** The local entry, external volume, and target path must match the migration record. The guardian matches the ShipIt request to the target, failure, and exit in the latest install attempt. It reads up to 1 MiB from the end of the log. A failure from days ago cannot justify acting on today’s update.
2. **Check the target and the cached update.** The guardian checks the app identifier and developer signature. If the external copy still exists, it also checks the developer matches and the replacement is newer. It waits while the installer or another operation has the resources it needs. Missing evidence leaves existing copies in place.
3. **Install and verify the result.** The guardian verifies the staged new copy before installing it at the original external path. When replacing an existing version, it retains that bundle and refreshes the local entry if it still exists. Task Center shows progress and the outcome of each recovery in a single **App Update Recovery** entry. If the same download fails signature verification twice, the guardian checks the previous version and automatically restores it once the app and installer exit. After refreshing the local entry, it removes the rejected download and temporary copies traced to this attempt. If it cannot verify a previous version, Task Center explains why and the recovery files are kept.

**How can I tell whether AppPorts stepped in?** Open Task Center and find the **App Update Recovery** entry for the app. **Update Recovered** means the guardian completed the recovery. If logging was enabled at the time, choose **View in Finder** under Settings → Log Settings. In `AppPorts_Log.txt`, search for the literal log message `已自动完成 ShipIt 更新恢复`. Check the timestamp and the `bundle_id` on the next line to identify the app. [Log settings](/docs/settings#logs)

A normal Sparkle update or a successful ShipIt installation can finish entirely within the app. If there is no recovery entry in Task Center, quit the app and reopen it from its original local entry to check which version is actually running. [Update protection and recovery](/docs/migration-strategy/portal#updates)

## What happens to the guardian when AppPorts updates {#handoff}

Before installing a new version of itself, AppPorts pauses the old guardian. If installation is cancelled or the installer fails to start, it resumes the guardian it paused. After replacing AppPorts manually from a DMG or ZIP, open the new app once to synchronize the background service. If you turned the guardian off before upgrading, it stays off.

The main window can appear while the new guardian is still starting. Apps that depend on the guardian show Available again once monitoring has started and the process, executable, and build match the running AppPorts. The badge shows Checking during this interval and refreshes automatically. If Settings continues to report that the guardian is unavailable, use Retry under Background agents. [Background agent settings](/docs/settings)

In an isolated macOS 15.7.7 test, build 80 installed a locally staged build 81 through its in-app installer. The new guardian started automatically. We replayed a known ShipIt failure using two originally signed copies of DeepSeek Harness and a log larger than 64 MiB. The guardian updated the external copy from 0.2.1-rc.2 to 0.2.2-rc.5, Task Center showed one successful recovery, and a cold launch from the original local entry opened the external rc.5. This test used a prepared candidate and failure record. The build was not published to the release feed.

## Updates tested on an external drive {#examples}

On November 21, 2026, IINA updated from **1.3.5 to 1.5.1** through Sparkle after an unlocked migration. After quitting and reopening it from the original local entry, the running process was the external 1.5.1 copy. IINA completed this update itself.

With the guardian off on macOS 15.7.7, Firefox updated from 160.0 to 160.0.1 and Google Chrome from 153.0.8010.48 to 158.0.8127.37. After quitting each app, we opened the original local entry and verified that it launched the new version on the external drive with a valid developer signature.

In isolation, CC Switch 4.0.30 updated to 4.0.38 when its temporary directory was on the same volume as the app. Reopening the original entry launched the vendor-signed external update. When AppPorts scans the app list, it refreshes eligible standard entries created by older builds. The change takes effect at the next normal launch. Launching the external copy directly or through a traditional symlink leaves older plugins using the system temporary directory.

Clash Verge stays on the Mac by default. When tested from an external volume in an isolated environment, version 2.5.5 asked to move back to the Mac at startup and quit when we selected Cancel.

On the same day, ShipIt failed and exited while updating DeepSeek Harness from **0.2.2-rc.3 to rc.5**. Its log had grown to about 64 MiB, and the old guardian could not read the latest result. In a retest, a separately launched build of the fixed guardian found that failure at the end of the log and completed the external installation. Task Center recorded a successful recovery. A cold launch from the original entry opened the external rc.5 copy. This test covered that request and its cached package. For a different ShipIt app, the evidence left by its own installation attempt determines whether recovery can proceed.
