---
outline: deep
---

# Settings

AppPorts' settings page is accessible via the gear icon in the upper right corner of the main window.

## App Store & iOS Settings

| Setting | Description | Default |
|---------|-------------|---------|
| App Store App Migration | Allows migration of App Store apps. Must be manually enabled on macOS versions below 15.1 | Off |
| iOS App Migration | Allows migration of iOS/iPadOS apps (Mac version) | Off |

::: tip 💡 macOS 15.1+ Users
macOS 15.1 and later support native App Store app installation to external drives. It is recommended to enable "Download and install large apps to an external drive" in App Store settings instead of using AppPorts' migration toggle.
:::

## Signing Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Auto Re-sign | Automatically executes Ad-hoc re-signing on associated apps after data directory migration | Off |
| Auto Re-sign at Login | Automatically re-signs migrated apps with expired signatures each time the user logs in | On |

When enabled, each data directory migration automatically backs up the original signature and executes re-signing to avoid "Damaged" prompts after migration.

When "Auto Re-sign at Login" is enabled, a LaunchAgent (`com.shimoko.AppPorts.re-sign`) is installed to scan signature backup records at each user login and automatically re-sign apps whose Ad-hoc signatures have expired. Re-sign logs are written to the AppPorts default log file.

::: tip 💡 Auto-Re-signing for Linked Apps
For linked apps (status: "Linked"), auto-re-signing automatically resolves the **real external app path** behind the Stub Portal shell or symlink, ensuring signature changes are applied to the actual application package. Backup and re-signing operations are identified by the real app's Bundle ID.
:::

## Logging Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Enable Logging | Writes runtime logs to file | On |
| Max Log Size | Automatically truncates older half when log file exceeds this size | 2 MB |
| Log Location | Log file save path | `~/Library/Application Support/AppPorts/AppPorts_Log.txt` |

### Log Operations

| Operation | Description |
|-----------|-------------|
| View in Finder | Opens the directory containing the log file |
| Export Diagnostic Package | Generates a ZIP file containing logs, operation records, and system info |
| Clear Log | Clears current log file contents |

For detailed log descriptions, see [Logging & Diagnostics](/en/logging).
