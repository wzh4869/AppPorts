# macOS 27 upgrades and repair

If you moved container data using an older method or allowed an app's signature to be replaced, update and open AppPorts to inspect existing migrations before upgrading to macOS 27. Newer versions improve checks and recovery, but **updating AppPorts does not automatically repair old signatures or convert old migrations**.

Old data entries, application identity and system permissions may no longer match. This page does not require everyone to upgrade macOS: it helps when planning an upgrade or handling a problem that has already occurred. For the reasons, see [macOS 27 and migration changes](/docs/principles/macos-27).

## Identify your situation {#check}

| What you see | Next step |
| --- | --- |
| Not yet upgraded; previously used classic container migration or re-signed apps | Connect the drive and inspect affected apps. Complete any required repairs below first. |
| Already upgraded; an app will not open and shows Signature replaced | Quit it, preserve the original data and open the repair instructions. |
| Signature check pending | Connect the external drive and retry inspection; do not immediately re-sign. |
| App and data work normally | Do not migrate again solely because the OS version changed. Maintain backups and use it normally. |

No warning badge does not prove every aspect of compatibility. If the signature checks out but the app still fails, continue with [general troubleshooting](/docs/faq#launch).

## Repair in order {#repair}

Click Signature replaced or Repair in the app list, or use View Repair Steps in its context menu. Connect the original external drive, quit related apps completely and retain existing copies before starting.

[![The signature repair panel first checks for legacy container links, then offers to restore the original signature, select an official copy, or check again (Simplified Chinese interface).](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-signature-repair-2d87d56892fc9472.png?sign=kbvJNzdSO_Qj7eg9Jx1xMV4WfyUsN7_8bh5vih6rXVo%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-signature-repair-2d87d56892fc9472.png?sign=kbvJNzdSO_Qj7eg9Jx1xMV4WfyUsN7_8bh5vih6rXVo%3D%3A0)

*The signature repair panel first checks for legacy container links, then offers to restore the original signature, select an official copy, or check again (Simplified Chinese interface).*

From 1.9.1 build 31, newly retained originals are in `AppPorts Backups` at an external volume's root. Restoration requires that drive even if the installed app remains internal. With several drives, it may differ from the current application library's drive. Connect the original drive and retry; temporary disconnection does not establish a missing backup. See [signature originals](/docs/settings#signature-backups) for location and cleanup rules.

1. **Handle old container links.** Restore related container data moved through legacy symbolic links to local storage first. APFS-mounted data need not all move back merely to repair a signature; follow the dependencies reported by the repair panel.
2. **Restore official app identity.** With a usable original, choose Restore Original Signature. Otherwise provide a matching official original as prompted or reinstall from the official source. Before an official overwrite installation, move an externally installed app back locally through AppPorts. A usable backup or matching same-version original can repair it in place. Avoid uninstall methods that also erase personal data.
3. **Check app and data access.** Open the app from Finder or the Dock and check existing content and normal saving. Successful launch only from a terminal is not a substitute for this check.
4. **Choose migration again if needed.** Once the app is working, eligible data can use mount migration; unsuitable data can stay local.

If any step reports an error, stop and preserve the data and paths shown. Restoring a signature is not another re-sign. Repeated re-signing cannot recover the original developer identity.

## Handle old login tasks {#after}

Older versions may have installed a task that re-signs apps at login. Open AppPorts once after updating so it can disable and remove that task. If settings reports unfinished cleanup, use Retry. Current builds disable background automatic re-signing on every macOS version. Build 31 removes the persistent switch, so normally no such settings card appears. [Background agents](/docs/settings#mount-agent) for container data and images remain available.

After restoring the app, some system permissions may need to be granted again. Connect the external drive before use; macOS still handles any applicable first-access prompts.

## Are my data damaged? {#data}

Signature replaced primarily indicates a change of app identity. It does not by itself establish that messages or files are damaged. Keep container directories, external data and backups, then inspect the contents after restoring access.

If both locations contain new data or a target conflict is reported, preserve both and use [troubleshooting](/docs/faq#conflict). Do not merge or overwrite them merely to clear the warning.

Related: [signature badges](/docs/badges#signing) · [classic mode](/docs/classic-mode) · [restore and relink](/docs/restore) · [export diagnostics](/docs/faq#feedback)
