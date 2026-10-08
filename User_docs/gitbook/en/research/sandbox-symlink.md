# Experiment Log: Sandboxed Apps + Symbolic Links (macOS 27)

This page is the raw record of a **controlled experiment**, intended for readers who want to check the evidence; for the user-facing conclusions, see [Container Data, Sandboxing and Signing Identity](../datamigrae/container-identity.md). The question the experiment answers:

> After container data is copied to an external volume and a symbolic link is left at the original location, can a sandboxed app read that data **without being re-signed**?

The answer is **no**. And it has nothing to do with the external volume: as long as the target is outside the container, the sandbox denies access.

{% hint style="success" %}
**Key Findings**

When a sandboxed app reads or writes container data, the kernel makes the sandbox decision based on the **real path after the symbolic link is resolved**.

- Pointing to `/Volumes/...` (external volume) → denied
- Pointing to `~/Desktop/...` (internal volume, outside the container) → also denied
- Pointing inside the container → allowed as normal

So for sandboxed apps, "migrate only, don't re-sign" is **not a safe option**; what it actually gives you is "the app launches, but cannot read its data."
{% endhint %}

## Environment <a href="#environment" id="environment"></a>

| Item | Value |
|------|-----|
| System | macOS 27.0 (26A428), Darwin 27.0.0, arm64 (T8132) |
| SIP | enabled |
| External volume | `/Volumes/hano` — `apfs, local, nodev, nosuid, journaled, noowners` |
| Test app A | Stickies — `/System/Applications/Stickies.app`, `com.apple.Stickies` |
| Test app B | WeChat 4.1.15 (270099) — developer-signed, not re-signed |
| Method | Symbolic-link redirection + launch with `open -a` + capture sandbox decisions with `log stream` |

### Entitlements of the Test Apps <a href="#entitlements-of-the-test-apps" id="entitlements-of-the-test-apps"></a>

Stickies (`com.apple.Stickies`), confirmed to be a sandboxed app:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.print</key><true/>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array><string>/Library/Preferences/widget-com.apple.widget.stickies.plist</string></array>
```

WeChat 4.1.15 (official Developer ID signature, `Tencent Mobile International Limited (5A4RE8SF68)`), likewise a sandboxed app and **not re-signed**:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key><array><string>5A4RE8SF68.com.tencent.xinWeChat</string></array>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
<key>com.apple.security.files.downloads.read-write</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array><string>com.tencent.xinWeChat-spks</string><string>com.tencent.xinWeChat-spki</string></array>
<key>com.apple.security.temporary-exception.sbpl</key>
<array><string>(allow network-outbound (literal "/private/var/run/usbmuxd"))</string></array>
```

Neither app has **any** temporary exception that covers arbitrary paths:

- `files.user-selected.*` applies only to files the user personally selects in an Open/Save panel; it does not cover fixed paths;
- `files.downloads.read-write` covers only `~/Downloads`;
- `temporary-exception.sbpl` opens only a single **network-outbound** literal and does not involve the file system.

## Results <a href="#results" id="results"></a>

### Stickies (Symbolic Link Redirecting `Data/Library/Stickies`) <a href="#stickies-symbolic-link-redirecting-data-library-stickies" id="stickies-symbolic-link-redirecting-data-library-stickies"></a>

| Scenario | Symlink target | App launches? | Data readable? | Sandbox deny log? | App recreated an empty directory? |
|------|--------------|:---:|:---:|:---:|:---:|
| Main experiment | `/Volumes/hano/sandbox-test/...` (external volume) | Yes | **No** | Yes | No |
| C1 | `~/Desktop/sandbox-test/...` (internal volume, outside the container) | Yes | **No** | Yes | No |
| C2 | Inside the container, `Data/tmp/relocated/...` | Yes | Yes | No | — |
| C3 | No symlink (original directory) | Yes | Yes | No | — |

The observable indicator was Stickies' **window count and window titles**: the original directory holds 2 notes. When the data is readable, Stickies restores 2 windows with their real titles; when it is not, only 1 blank "Untitled" (`未命名`) window remains.

```
场景                        窗口数  窗口标题
主实验（/Volumes）            1     未命名              ← 读不到
C1（~/Desktop）               0     —                   ← 读不到
C2（容器内）                  2     制作便条！… / 自定便条很简单。…
C3（阳性对照）                2     制作便条！… / 自定便条很简单。…
```

In all three "symlink denied" runs, the symbolic link itself stayed **intact**, and the app did not recreate a local directory of the same name. It simply could not read the data and carried on as if there were no notes at all.

### WeChat (Symbolic Link Redirecting `Data/Documents/xwechat_files/wxid_...`) <a href="#wechat-symbolic-link-redirecting-data-documents-xwechat-files-wxid" id="wechat-symbolic-link-redirecting-data-documents-xwechat-files-wxid"></a>

| Scenario | App signature | Data location | App launches? | Data readable? | Logs |
|------|----------|----------|:---:|:---:|------|
| W1 | Ad-hoc re-signed | External volume (symlink) | No (exits after ~0.9 s) | No | TCC App Data denial |
| W2 | Official signature | External volume (symlink) | Yes | **No** | Sandbox `file-read-data` denial + UI error |
| W3 | Official signature | Local (positive control) | Yes | Yes | No denials |
| W4 | Ad-hoc re-signed | Local | No (exits immediately) | No | TCC App Data denial |

## Decisive Raw Logs <a href="#decisive-raw-logs" id="decisive-raw-logs"></a>

### Stickies · Main Experiment (External Volume) <a href="#stickies-·-main-experiment-external-volume" id="stickies-·-main-experiment-external-volume"></a>

```
2026-09-18 06:19:41.380 E  kernel[0:5f489] (Sandbox) Sandbox: Stickies(41548) deny(1) file-read-data /Volumes/hano/sandbox-test/com.apple.Stickies/Library-Stickies/.SavedStickiesState
2026-09-18 06:19:41.468 E  kernel[0:5f489] (Sandbox) Sandbox: Stickies(41548) deny(1) file-read-data /Volumes/hano/sandbox-test/com.apple.Stickies/Library-Stickies
2026-09-18 06:19:43.485 E  kernel[0:5f489] (Sandbox) Sandbox: Stickies(41548) deny(1) file-write-unlink /Volumes/hano/sandbox-test/com.apple.Stickies/Library-Stickies/.SavedStickiesState
```

### Stickies · C1 (Path Inside the Home Folder but Outside the Container) <a href="#stickies-·-c1-path-inside-the-home-folder-but-outside-the-container" id="stickies-·-c1-path-inside-the-home-folder-but-outside-the-container"></a>

```
2026-09-18 06:20:08.519 E  kernel[0:6024f] (Sandbox) Sandbox: Stickies(42084) deny(1) file-read-data /Users/<user>/Desktop/sandbox-test/com.apple.Stickies-Library-Stickies/.SavedStickiesState
2026-09-18 06:20:08.599 E  kernel[0:6024f] (Sandbox) Sandbox: Stickies(42084) deny(1) file-read-data /Users/<user>/Desktop/sandbox-test/com.apple.Stickies-Library-Stickies
2026-09-18 06:20:08.599 E  kernel[0:6024f] (Sandbox) Sandbox: Stickies(42084) deny(1) file-write-create /Users/<user>/Desktop/sandbox-test/com.apple.Stickies-Library-Stickies/DB5CDB21-9A90-438C-ACCB-614F1F0018DE.rtfd
```

The denials in C1 take **exactly the same form** as in the main experiment, which shows that what matters is "the path is outside the container," not "the path is under `/Volumes`."

### WeChat · W2 (Official Signature + External Volume) <a href="#wechat-·-w2-official-signature-external-volume" id="wechat-·-w2-official-signature-external-volume"></a>

The UI explicitly reports an error:

> ⚠️ 存储权限异常
> 存储位置不能使用，WeChat 将无法使用，请检查此文件夹是否可用。

(In English: "Storage permission error. The storage location cannot be used; WeChat will not be usable. Please check whether this folder is available.")

The corresponding sandbox log:

```
2026-09-18 06:25:26.194 E  kernel[0:5f65e] (Sandbox) WeChat(43498) deny(1) file-read-data /Volumes/hano/appdisks/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1zxh3e4ctfeh22_9c44/db_storage/contact/contact.db
```

**Without being re-signed**, WeChat was denied by the sandbox when reading its own contacts database. At that point it had already launched successfully and was showing the account avatar and nickname (these come from local files under `all_users/` inside the container), but it failed as soon as it actually tried to read the account data directory.

### WeChat · W3 (Official Signature + Local Data, Positive Control) <a href="#wechat-·-w3-official-signature-local-data-positive-control" id="wechat-·-w3-official-signature-local-data-positive-control"></a>

With the same data put back locally inside the container, WeChat opened all of its databases normally:

```
WeChat 46541 wangheng  101r  REG  1,14  8450048  99926627 /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1zxh3e4ctfeh22_9c44/db_storage/contact/contact.db
WeChat 46541 wangheng   99u  REG  1,14  4194304  99926632 /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1zxh3e4ctfeh22_9c44/db_storage/contact/contact.db-wal
```

The chat list was displayed in full, the history was readable, and there was no `deny` of any kind.

### WeChat · W1 / W4 (Ad-hoc Re-signed) <a href="#wechat-·-w1-w4-ad-hoc-re-signed" id="wechat-·-w1-w4-ad-hoc-re-signed"></a>

```
Failed to match existing code requirement for subject com.tencent.xinWeChat and service kTCCServiceSystemPolicyAppDataDetailed
sandboxd rejected approval request from WeChat for kTCCServiceSystemPolicyAppData (/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/net/config.ini): denied
```

In W4 the data was **entirely local**, and the logs contain no `/Volumes`-related denials at all. This shows that the failure caused by re-signing is unrelated to where the data is stored; it is a separate, independent failure chain.

## Conclusions <a href="#conclusions" id="conclusions"></a>

| | Data local | Data on external volume (symlink) |
|---|---|---|
| **Official signature (sandboxed)** | ✅ Works; chat history complete | ❌ Launches normally, reads denied ("存储权限异常", storage permission error) |
| **Ad-hoc re-signed (not sandboxed)** | ❌ TCC App Data denial, exits immediately | ❌ TCC App Data denial, exits immediately |

Three independent conclusions:

1. **A sandboxed app cannot follow a symbolic link to read data outside its container.** The kernel decides based on the resolved real path; `/Volumes` and `~/Desktop` give the same result. The symbolic link itself is not the problem: when the target is inside the container, everything works (C2).
2. **Re-signing independently breaks container ownership.** Even with the data entirely local, an Ad-hoc re-signed app is denied access to its own container by `kTCCServiceSystemPolicyAppData` (W4).
3. **"Migrate only, don't re-sign" is not viable for sandboxed apps.** The app does not crash, but it silently fails to read its data and shows an error along the lines of "storage location unavailable", which is harder to troubleshoot than an outright launch failure.

### What This Means for AppPorts <a href="#what-this-means-for-appports" id="what-this-means-for-appports"></a>

For directories under `~/Library/Containers/` and `~/Library/Group Containers/`:

- **"Forbidding re-signing" is not enough to solve the problem**: without re-signing, the data still cannot be read;
- For sandboxed apps, symbolic-link migration **does not work at the mechanism level**, regardless of macOS version (on macOS 26 it "worked" because re-signing stripped out the sandbox, not because the symbolic link took effect).

Based on this experiment, starting with AppPorts 1.9.0 only [mount migration](../datamigrae/mount-migration.md) is offered for container directories; the follow-up [mount point experiment](sandbox-mountpoint.md) validated that approach.

### Limits of This Experiment <a href="#limits-of-this-experiment" id="limits-of-this-experiment"></a>

- Stickies is a system app under `/System/Applications` on the read-only system volume, and AppPorts would never migrate it anyway. It was used only to verify **the sandbox mechanism itself**; the conclusions do not depend on the specific app.
- The WeChat test used a `WeChat.app` freshly reinstalled from the official channel (Developer ID, not re-signed), which behaves the same as the App Store / official website version.
- `~/Library/Group Containers/` was not tested, but its path decisions work the same way as for `Containers` (it likewise falls outside the container allowlist).
