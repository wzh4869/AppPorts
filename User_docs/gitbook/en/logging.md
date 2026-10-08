# Logging & Diagnostics

AppPorts has a built-in logging system that records key events, migration operations, system information, and error details during app runtime. When issues arise, you can export a diagnostic package and submit it to the project [Issues](https://github.com/wzh4869/AppPorts/issues) for troubleshooting.

## Logged Content <a href="#logged-content" id="logged-content"></a>

### Startup Session Information <a href="#startup-session-information" id="startup-session-information"></a>

The following information is recorded each time the app starts:

| Item | Description |
|------|-------------|
| Session ID | Unique identifier for this run (8-character UUID prefix) |
| Process ID | System process identifier |
| Bundle ID | App identifier |
| App Language | Currently selected language code |
| System Locale | System locale identifier |
| Timezone | Current timezone identifier |
| Preferred Language List | System preferred language order |

### System Diagnostic Information <a href="#system-diagnostic-information" id="system-diagnostic-information"></a>

| Item | Description |
|------|-------------|
| App Version | Version number and build number |
| macOS Version | System version and marketing name (e.g., "macOS Sequoia 15.x") |
| Device Model | Model and friendly name (e.g., "MacBook Pro (14-inch, M3 Pro, 2023)") |
| Processor Info | Brand string, core count, active core count |
| Physical Memory | Total memory |

### External Storage Information <a href="#external-storage-information" id="external-storage-information"></a>

Recorded when selecting an external storage volume:

| Item | Description |
|------|-------------|
| Volume Name | Storage volume name |
| Total Capacity / Available Space | Storage space information |
| File System Format | e.g., APFS, HFS+, exFAT, etc. |
| Interface Protocol | USB, Thunderbolt, NVMe/SATA |
| Device Speed | Transfer rate information |
| Block Size | Storage block size |
| Volume UUID | Storage volume unique identifier |

### Migration Operation Events <a href="#migration-operation-events" id="migration-operation-events"></a>

Each migration operation generates a unique operation ID (e.g., `data-migrate-ABCD1234`), recording:

- Operation start and end
- Progress of each step (copy, delete original directory, create symbolic link, rollback)
- Path state snapshots before and after steps (existence, permissions, size, symlink target, immutable flag)
- Residual migration data detection and auto-recovery
- File copy progress, errors, and retries

### Migration Performance Reports <a href="#migration-performance-reports" id="migration-performance-reports"></a>

| Item | Description |
|------|-------------|
| App Name | Migrated app name |
| Data Size | Migrated data volume |
| Duration | Migration duration (seconds) |
| Transfer Speed | Transfer rate (MB/s) |
| Source Path / Destination Path | Migration start and end paths |

### Error Details <a href="#error-details" id="error-details"></a>

Error logs contain structured information:

| Field | Description |
|-------|-------------|
| Error Description | Human-readable error description |
| Error Type / Domain / Code | NSError structured information |
| Error Code | AppPorts internal error code (see table below) |
| Failure Reason | Detailed failure reason |
| Recovery Suggestion | System-provided recovery suggestion |
| File Path | Affected file path |
| Related Paths | Related app paths involved in the operation (`relatedURLs`) |
| Underlying Error | Nested error recorded recursively |

### Error Codes <a href="#error-codes" id="error-codes"></a>

| Error Code | Meaning |
|------------|---------|
| `BACKUP-SIGNATURE-FAILED` | Signature backup failed |
| `APP-MOVE-DESTINATION-CONFLICT` | App migration target already exists and cannot be confirmed safe to replace |
| `APP-RESTORE-LOCAL-CONFLICT` | Move-back found a same-name local item that cannot be overwritten automatically |
| `DATA-MIGRATE-DESTINATION-CONFLICT` | Data migration target already exists and metadata does not fully match |
| `RESIGN-FAILED` | Re-signing failed (app may not pass macOS signature verification) |
| `DATA-RESIGN-FAILED` | Auto-re-signing after data directory migration failed |
| `RESIGN-REFUSED-SANDBOXED` | Re-signing a sandboxed app was refused |
| `RESTORE-SIGNATURE-IDENTITY-UNAVAILABLE` | The original signing certificate is not on this Mac; restoration was refused |
| `CONTAINER-MOUNT-*` | A mount migration stage failed, for example `CONTAINER-MOUNT-EXTERNAL-NOT-APFS` or `CONTAINER-MOUNT-SWITCH-FAILED` |
| `CONTAINER-RESTORE-*` | A stage of restoring a mount-migrated directory failed |
| `DATA-BACKUP-SIGNATURE-FAILED` | Signature backup before data directory migration failed (original signature cannot be restored later) |

### Data Directory Operation Context <a href="#data-directory-operation-context" id="data-directory-operation-context"></a>

Data directory operations (migration, restore, normalization, relinking) automatically include associated app context information in logs:

| Field | Description |
|-------|-------------|
| `app_name` | Associated app name |
| `app_status` | App status (Linked, Local, etc.) |
| `app_is_resigned` | Whether the app has been re-signed |
| `app_bundle_id` | App's Bundle ID (read from real path) |
| `app_real_path` | App's real external path |

### Operation Summary <a href="#operation-summary" id="operation-summary"></a>

Each migration operation generates an `OperationSummaryRecord`, retaining the most recent 100 records:

| Field | Description |
|-------|-------------|
| `operationID` | Operation unique identifier |
| `category` | Operation category (`app_move`, `data-migrate`, `file-copy`, etc.) |
| `result` | Result (`success`, `failed`, `rolled_back`, `success_with_warning`) |
| `errorCode` | Error code (if any) |
| `startedAt` / `endedAt` | Start and end time |
| `durationMs` | Duration (milliseconds) |

## Log Configuration <a href="#log-configuration" id="log-configuration"></a>

### Storage Location <a href="#storage-location" id="storage-location"></a>

Default log path:

```text
~/Library/Application Support/AppPorts/AppPorts_Log.txt
```

Can be customized via:

- Menu bar → Logs → Set Log Location
- Settings → Logging Settings → Custom Path

### Log Format <a href="#log-format" id="log-format"></a>

```text
[2026-05-08 09:30:00] [INFO] [session:a1b2c3d4] [pid:12345] 应用启动
[2026-05-08 09:30:01] [DIAG] [session:a1b2c3d4] [pid:12345]   app_version: 1.6.1 (123)
[2026-05-08 09:30:05] [PERF] [session:a1b2c3d4] [pid:12345]   迁移完成: 2.3 GB, 45.2 MB/s, 52.1s
```

### Log Levels <a href="#log-levels" id="log-levels"></a>

| Level | Description |
|-------|-------------|
| `INFO` | General information |
| `ERROR` | Error information (with structured error details) |
| `DIAG` | System diagnostic information |
| `DISK` | External storage volume information |
| `PERF` | Migration performance report |
| `TRACE` | Low-level path state and folder monitoring |
| `DEBUG` | Debug information (size calculation, nested directory checks) |
| `WARN` | Warnings (residual migration data, recovery mode) |

### Log Rotation <a href="#log-rotation" id="log-rotation"></a>

- Default max size: **2 MB** (configurable: 1 MB, 5 MB, 10 MB, 50 MB, 100 MB)
- Auto-truncation when exceeded: Discards older half of lines, keeps newer half

## Export Diagnostic Package <a href="#export-diagnostic-package" id="export-diagnostic-package"></a>

When issues arise requiring feedback, please export a diagnostic package and attach it to the Issue.

### Export Methods <a href="#export-methods" id="export-methods"></a>

**Method 1: Menu Bar**

1. Click Menu bar → Logs → Export Diagnostic Package
2. Choose save location
3. System automatically generates a `.zip` file and opens in Finder

**Method 2: Settings Page**

1. Open AppPorts → Settings (upper right corner)
2. Find the "Logging Settings" section
3. Click "Export Diagnostic Package" button
4. Choose save location

### Diagnostic Package Contents <a href="#diagnostic-package-contents" id="diagnostic-package-contents"></a>

The exported `AppPorts-Diagnostic-<datetime>.zip` contains:

| File | Format | Description |
|------|--------|-------------|
| `diagnostic-summary.json` | JSON | Metadata (session ID, version, locale, timezone, etc.) |
| `diagnostic-summary.txt` | Plain text | Human-readable diagnostic summary |
| `recent-operations.json` | JSON | Most recent 100 operation records |
| `recent-failures.json` | JSON | Most recent 20 failed/warning operations |
| `AppPorts_Log.share-safe.txt` | Plain text | Complete log (redacted) |

### Privacy Protection <a href="#privacy-protection" id="privacy-protection"></a>

Log files in the diagnostic package are redacted:

| Original Content | Replaced With |
|------------------|---------------|
| User home directory path (e.g., `/Users/john`) | `/Users/<redacted-user>` |
| External storage volume name (e.g., `/Volumes/MyDrive`) | `/Volumes/<redacted-volume>` |
| `$HOME` full path | `~` |

## Submitting Issues <a href="#submitting-issues" id="submitting-issues"></a>

After obtaining the diagnostic package, follow these steps to submit:

1. Visit the project [Issues](https://github.com/wzh4869/AppPorts/issues) page
2. Click "New Issue," select the Bug report template
3. Describe the issue and reproduction steps
4. Drag the diagnostic `.zip` file to the attachment area to upload
5. Submit the Issue

{% hint style="success" %}
**💡 Improve Feedback Efficiency**

Submitting Issues with diagnostic packages can significantly speed up issue resolution. The diagnostic package contains complete operation history, error details, and system environment information, allowing developers to reproduce and analyze issues without repeated communication.
{% endhint %}
