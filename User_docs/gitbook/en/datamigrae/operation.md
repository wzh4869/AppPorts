---
icon: "arrows-left-right"
description: "Follow the steps to migrate or restore data directories."
layout:
  width: "default"
  outline:
    visible: true
---

# Data Migration Guide

This page explains how to migrate data directories. For the technical implementation, see [How Data Migration Works](baseinfo.md).

## Find an App's Data Directories <a href="#find-an-app-s-data-directories" id="find-an-app-s-data-directories"></a>

1. Open the "Data Directories" tab in the AppPorts main window.
2. Switch between "Tool Directories" and "App Data" at the top.
3. In App Data, select an app on the left. Its associated directories under `~/Library/` appear on the right.

AppPorts matches these locations using the app's Bundle ID or name:

| Scanned Path | Matching Method | Migration Method |
|--------------|-----------------|------------------|
| `~/Library/Application Support/` | Bundle ID or app name | Symbolic link |
| `~/Library/Preferences/` | Bundle ID or app name | Symbolic link |
| `~/Library/Containers/` | Bundle ID | **Mount migration** |
| `~/Library/Group Containers/` | Bundle ID | **Mount migration** |
| `~/Library/Caches/` | Bundle ID or app name | Symbolic link |
| `~/Library/WebKit/` | Bundle ID | Symbolic link |
| `~/Library/HTTPStorages/` | Bundle ID | Symbolic link |
| `~/Library/Application Scripts/` | Bundle ID | Symbolic link |
| `~/Library/Logs/` | App name | Symbolic link |
| `~/Library/Saved Application State/` | App name | Symbolic link |

For why containers need a different method, see [Mount Migration](mount-migration.md).

## Tool Directories <a href="#tool-directories" id="tool-directories"></a>

AppPorts recognizes directories created by common development tools under your home directory, such as `~/.npm` and `~/.gradle`:

1. Select "Tool Directories" in the "Data Directories" tab.
2. The list shows recognized directories, their sizes, priorities, and statuses.

If the local directory is missing but an AppPorts-managed directory remains at the standard external location, it is shown as "Awaiting Relink". See [Tool Directory Detection](tools.md) for the supported list.

## Directory Migration for Custom Folders <a href="#directory-migration-for-custom-folders" id="directory-migration-for-custom-folders"></a>

Use the "Directory Migration" tab to move arbitrary folders under your home directory, such as large projects, models, and asset libraries.

1. Open "Directory Migration".
2. Click "+" in the "Local Folders" heading.
3. Select a local folder, then a destination root on the external drive. The destination is `目标根目录/文件夹名`.

Validation rules: the local folder must be inside your home directory and cannot be the home directory itself. Neither it nor any parent path may be a symbolic link. It must not contain, or be contained by, an already managed directory. The external destination must be outside your home directory, and it must not overlap the local folder in either direction.

After migration, the local pane shows the original path's status and the external pane shows the copy's status. "Relink" and "Restore" are available. Removing a configuration removes only the record, not the data.

## Symbolic-Link Migration <a href="#symbolic-link-migration" id="symbolic-link-migration"></a>

Use this for directories outside containers.

1. Find the directory and click "Migrate".
2. AppPorts copies it to the external drive, writes the management marker, renames the original directory to a safety backup, creates a symbolic link at the original path, and finally removes the backup.
3. The status changes to "Linked".

{% hint style="success" %}
**Re-sign after migration**

The "Re-sign after migration" switch in the Data Directories toolbar is off by default. When enabled, it applies an Ad-hoc signature to the associated app after migration, to address a "damaged" message; sandboxed apps are skipped. It is usually unnecessary. See [Re-signing and Crash Prevention](resign.md).
{% endhint %}

## Mount Migration <a href="#mount-migration" id="mount-migration"></a>

Directories under `Containers` and `Group Containers` show a "Mount migration" button.

1. Make sure the external drive uses APFS, then quit the associated app.
2. Click "Mount migration", read the three notices in the confirmation dialog, and continue.
3. AppPorts creates a volume on the external drive, copies the data, and mounts it at the original directory.
4. The status changes to "Mounted". Allow the system permission prompt the first time you open the app.

See [Mount Migration](mount-migration.md) for the full guide.

## Restore <a href="#restore" id="restore"></a>

**Symbolic-link migrations** ("Linked"): click "Restore". AppPorts copies the data back to this Mac, removes the symbolic link, and then deletes the external copy.

**Mount migrations** ("Mounted" or "Awaiting mount"): click "Restore". AppPorts copies the volume's data back to this Mac, then unmounts and deletes the volume. Keep the external drive connected.

Both methods copy first and switch paths afterward, so a failure midway does not lose data.

## Handle Unusual Statuses <a href="#handle-unusual-statuses" id="handle-unusual-statuses"></a>

| Status | Meaning | Action |
|--------|---------|--------|
| Needs Normalization | AppPorts manages the link, but its external path is not in the standard location | "Normalize" moves the external data to the standard path and recreates the link |
| Awaiting Relink | The external data exists but the local link is missing | "Relink" recreates the symbolic link |
| Existing Symlink | A symbolic link created outside AppPorts | Open "Link Details" to bring it under AppPorts management |
| Awaiting mount | The mount-migrated volume is online but not mounted | Click "Mount" |
| Drive Not Connected | The data volume cannot be found | Connect the external drive; AppPorts reconnects it automatically |

Relinking and normalization apply only to directories. If a regular file occupies the external destination, AppPorts stops and preserves it.

## Log Context <a href="#log-context" id="log-context"></a>

Data directory operations log information about the associated app to help diagnose problems:

| Field | Description |
|-------|-------------|
| `app_name` | Associated app name |
| `app_status` | App status |
| `app_is_resigned` | Whether the app has been re-signed |
| `app_bundle_id` | The real app's Bundle ID |
| `app_real_path` | The real app's path |

Mount migration also logs the volume name, Volume UUID, and `diskutil` output.

## Tree View <a href="#tree-view" id="tree-view"></a>

Directories with subdirectories appear as a tree. An arrow to the left expands the parent directory; children are indented. Each node has its own size, status, and action buttons.
