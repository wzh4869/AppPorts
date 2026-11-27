# Quick start

You need a Mac running macOS 12 or later and a reliably connected external drive with enough free space. This page covers installation and your first application migration. To move messages, caches, models or other data instead, complete preparation and continue to [Move data](/docs/datamigrae/operation).

## Download and install {#install}

1. Download AppPorts from the [download page](https://file.shimoko.com/AppPorts) or [GitHub Releases](https://github.com/wzh4869/AppPorts/releases) and move AppPorts into your Mac's Applications folder. You can also install it with Homebrew:

```sh
brew install --cask wzh4869/tap/appports
```

For Homebrew upgrade and uninstall commands, see the [AppPorts tap](https://github.com/wzh4869/homebrew-tap#readme).

2. Open AppPorts from Applications and follow the onboarding guide: first-time users step through core capabilities overview → **Boundaries** → **Readiness**, while users upgrading from an earlier version confirm the single-screen **Boundaries & Shared Understanding of AppPorts** notice once without resetting existing permissions, moved apps, or records (reviewable anytime from **Boundaries** at the top of Settings). AppPorts verifies that it is running from Applications before starting new migrations, operating on disk images or opening permission guides; do not keep running it from the installer image or a temporary folder.

[![Open the DMG, drag AppPorts from the left onto the Applications folder on the right, and release it.](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-install-drag-5d967c0d07f9edcb.gif?sign=2fap3x95UNN19dzzLIznjNIjszdqpbwLfVZIy8H99A8%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-install-drag-5d967c0d07f9edcb.gif?sign=2fap3x95UNN19dzzLIznjNIjszdqpbwLfVZIy8H99A8%3D%3A0)

*Open the DMG, drag AppPorts from the left onto the Applications folder on the right, and release it.*

## Prepare permissions and storage {#permissions}

1. Connect the external drive and choose a folder under Destination Storage in the sidebar; for a NAS share or non-APFS drive, you can also create or open an [APFS app library image](/docs/storage-guide#app-library-image) from the same menu.
2. Click the settings gear at the bottom of the sidebar (or press `Command + ,`) and inspect Readiness. Click Open System Settings to enable Full Disk Access for AppPorts, and grant App Management access if required; if AppPorts is not listed yet, drag the AppPorts icon from the floating guide directly into System Settings.
3. Reopen AppPorts when prompted. Use Check beside the Readiness heading to verify the status.

[![Open Settings from the bottom of the sidebar, then click Check to refresh readiness (Simplified Chinese interface).](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-readiness-pointer-4e6a0bbfbc33714f.gif?sign=QeBq7i0li3XCK2-rJQ89siGLCGWWhMHhGhMYNX8Apyo%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-readiness-pointer-4e6a0bbfbc33714f.gif?sign=QeBq7i0li3XCK2-rJQ89siGLCGWWhMHhGhMYNX8Apyo%3D%3A0)

*Open Settings from the bottom of the sidebar, then click Check to refresh readiness (Simplified Chinese interface).*

**Only mount migration of container data requires APFS storage.** Ordinary apps and folders have their own checks. You do not need to erase an existing disk for your first application migration. If its format is unsuitable, read [storage preparation](/docs/storage-guide#apfs).

## Complete your first move {#first-move}

1. Choose an app you know, save your work and quit it completely.
2. Open Apps in the sidebar, select the app under Local Apps and choose Move to External.
3. Read the destination, update-protection or conflict messages, then confirm the content you intend to move.
4. Wait for copying, verification and cleanup to finish. Keep the drive connected and do not reopen the app during the operation.
5. Open the moved app from Finder or the Dock and check its main features.

The real app now lives on external storage and a launch entry remains locally. The list shows the relevant [status badges](/docs/badges). If a destination already exists, permissions are missing or the operation stops, follow the prompt rather than deleting either copy yourself.

## Next steps {#next}

- App opens normally: learn about [updates after migration](/docs/core#updates).
- Want to move its data: read [Move data](/docs/datamigrae/operation).
- Want local storage again: read [restoration and reconnection](/docs/restore).
- Operation incomplete or app will not open: find the symptom in [troubleshooting](/docs/faq).

Migration changes where content is stored; it does not replace a backup. Connect the drive before using moved content. Before disconnecting it, quit apps using it and eject it normally.
