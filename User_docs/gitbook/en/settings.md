# Settings

AppPorts' settings page is accessible via the gear icon in the upper right corner of the main window.

## App Store & iOS Settings <a href="#app-store-ios-settings" id="app-store-ios-settings"></a>

| Setting | Description | Default |
|---------|-------------|---------|
| App Store App Migration | Allows migration of App Store apps. Must be manually enabled on macOS versions below 15.1 | Off |
| iOS App Migration | Allows migration of iOS/iPadOS apps (Mac version) | Off |

{% hint style="success" %}
**💡 macOS 15.1+ Users**

macOS 15.1 and later support native App Store app installation to external drives. It is recommended to enable "Download and install large apps to an external drive" in App Store settings instead of using AppPorts' migration toggle.
{% endhint %}

## Signing Settings <a href="#signing-settings" id="signing-settings"></a>

| Setting | Location | Description | Default |
|---------|----------|-------------|---------|
| Re-sign after migration | Top toolbar of Data Directories, **visible only in classic mode** | Applies an Ad-hoc signature to the associated app after symbolic-link migration | Off |
| Auto Re-sign at Login | Settings | Re-signs apps recorded as originally Ad-hoc in their signature backups to handle signatures becoming invalid after a restart; skips sandboxed apps except in classic mode | Off for new installations; remains on for existing users who already installed the login agent |

Outside classic mode, sandboxed apps cannot be re-signed through any entry point: re-signing may prevent them from opening on macOS 27. Container data uses [mount migration](datamigrae/mount-migration.md), which needs no signature changes.

The login script does not re-sign apps with new records containing a complete original app backup. AppPorts verifies signing operations and safely replaces the app. The installed script is synchronized when AppPorts starts.

"Auto Re-sign at Login" installs the LaunchAgent `com.shimoko.AppPorts.re-sign` and writes to the default AppPorts log. Re-signing and backups target the real app on the external drive, rather than the local launcher. See [Re-signing and Crash Prevention](datamigrae/resign.md).

## Classic Data Migration Mode (Not Recommended) <a href="#classic-data-migration-mode" id="classic-data-migration-mode"></a>

This switch is at the bottom of Settings and is off by default. It is retained for users who already rely on the 1.8.1 workflow and cannot switch yet. If the external drive is not APFS, keep container data on this Mac instead of enabling this mode to bypass the APFS requirement. See [Why External Drives Must Use APFS](why-apfs.md#what-to-do). Before enabling it, select "I understand these risks" in the confirmation dialog. On macOS 27, a message beside the switch explains that re-signed sandboxed apps may not open. Enabling it changes the following:

| Item | Off (default) | On |
|------|---------------|----|
| Container directory buttons | "Mount migration" only | "Migrate" (symbolic link) alongside "Mount migration" |
| Re-signing dialog before container migration | Hidden | Shown, with migration only selected by default |
| Re-signing sandboxed apps | Refused at every entry point | Allowed, with a second confirmation explaining the consequences each time |
| "Re-sign after migration" switch | Hidden | Shown in the Data Directories toolbar |
| "Normalize", "Relink", and "Link Details" for containers | Disabled, with instructions to restore before using mount migration | Available |

Classic mode restores the complete old workflow, including its risks. Re-signed sandboxed apps may not open on macOS 27, requiring data restoration and reinstallation. AppPorts marks these apps "Signature replaced" and reminds you at startup; see [Upgrading to macOS 27](macos-27.md). Turning classic mode off does not change existing symbolic-link migrations, and "Restore" remains available.

## Mount Migration <a href="#mount-migration" id="mount-migration"></a>

Mount migration has no separate setting. "Readiness" in Settings checks Full Disk Access, the AppPorts installation location, and the external storage format, and explains what needs attention. After the first successful mount migration, AppPorts installs the login agent `com.shimoko.AppPorts.container-mount` to remount online volumes at their container directories after login. It is uninstalled automatically when the last mount record is restored. On older systems such as macOS 12, the agent cannot display an administrator password prompt; open AppPorts after login to finish remounting.

## Logging Settings <a href="#logging-settings" id="logging-settings"></a>

| Setting | Description | Default |
|---------|-------------|---------|
| Enable Logging | Writes runtime logs to file | On |
| Max Log Size | Automatically truncates older half when log file exceeds this size | 2 MB |
| Log Location | Log file save path | `~/Library/Application Support/AppPorts/AppPorts_Log.txt` |

### Log Operations <a href="#log-operations" id="log-operations"></a>

| Operation | Description |
|-----------|-------------|
| View in Finder | Opens the directory containing the log file |
| Export Diagnostic Package | Generates a ZIP file containing logs, operation records, and system info |
| Clear Log | Clears current log file contents |

For detailed log descriptions, see [Logging & Diagnostics](logging.md).

Before a manual backup, re-sign, or restoration, AppPorts stops the background re-signing task for the current login and waits for its child processes to exit, so it cannot overwrite a freshly restored signature. The login agent configuration remains, and the setting applies again at the next login. If AppPorts cannot confirm that the background task has stopped, the manual operation is aborted.
