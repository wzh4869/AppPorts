---
icon: "hard-drive"
description: "Experiments with sandboxed apps accessing data through mount points."
layout:
  width: "default"
  outline:
    visible: true
---

# Experiment Log: Sandboxed Apps + Mount Points (macOS 27)

This page is the raw record of the second round of **controlled experiments**, following the [symbolic link experiment](sandbox-symlink.md), intended for readers who want to check the evidence; for the user-facing explanation, see [Mount Migration](../datamigrae/mount-migration.md). The question the experiment answers:

> Without re-signing, if an APFS volume on the external drive is **mounted directly onto the original path inside the container** (so the real path stays inside the container), can sandboxed apps read and write that data?

The answer **varies by app**, and it depends on something unrelated to the sandbox path rules: TCC's **"Removable Volumes" authorization**.

{% hint style="success" %}
**Key Findings**


- A mount point **really does bypass the sandbox's path check**: the sandbox only compares path strings, a mount point on the container path matches, and the kernel no longer judges the access to be "outside the container."
- But data residing on an **external volume** additionally triggers a `kTCCServiceSystemPolicyRemovableVolumes` (Removable Volumes) check:
  - **Third-party apps** (WeChat, Maccy, Xiaomi Interconnectivity) → the system shows an authorization prompt to "access removable volumes"; once allowed, **reads and writes work completely normally**;
  - **Platform apps** (Stickies) → **no prompt, just a silent denial**; the app launches as usual but cannot read any data, and may recreate an empty store.
- The act of "mounting onto the container path" itself also requires **Full Disk Access**: an ordinary background process (for example, a script-based LaunchAgent) is denied by `kTCCServiceSystemPolicyAppDataDetailed`.
{% endhint %}

## Environment <a href="#environment" id="environment"></a>

| Item | Value |
|------|-----|
| System | macOS 27.0 (26A428), Darwin 27.0.0, arm64 (T8132) |
| External volume | `/Volumes/hano` — `apfs, local, nodev, nosuid, journaled, noowners` (APFS, container `disk7`) |
| Test volume | Temporary volume newly created with `diskutil apfs addVolume disk7 APFS ...` (no root needed) |
| Test app A | Stickies — `/System/Applications/Stickies.app` (platform app) |
| Test app B | WeChat 4.1.15 — official Developer ID signature, **not re-signed** |
| Test app C | Maccy — third-party sandboxed app (Developer ID) |
| Test app D | Xiaomi Interconnectivity (小米互联服务) — **App Store (MAS) sandboxed app** |
| Method | Mount-point redirection + launch with `open -a` + capture TCC / sandbox decisions with `log stream` |
| Throughout | **No `codesign --sign` was run at any point** |

## Method <a href="#method" id="method"></a>

```
SUB=~/Library/Containers/<BundleID>/Data/<子目录>     # 应用启动时会读写的子目录
EXT=/Volumes/<测试卷>

rsync -a "$SUB"/ ~/sandbox-test-backup/.../            # 备份
rsync -a "$SUB"/ "$EXT"/                               # 数据进卷
diskutil unmount "$EXT"
mv "$SUB" "$SUB.local-original"; mkdir "$SUB"          # 原目录让位
diskutil mount -mountPoint "$SUB" <测试卷>             # 卷挂到容器路径上
```

After mounting, `mount` shows the container path itself:

```
/dev/disk7s5 on /Users/<user>/Library/Containers/com.apple.Stickies/Data/Library/Stickies (apfs, local, nodev, nosuid, journaled, noowners)
```

## Summary of Results <a href="#summary-of-results" id="summary-of-results"></a>

| Scenario | Mount needs sudo | App launches | Reads data on the volume | Writes to the volume | Sandbox / TCC logs | Notes |
|------|--------------|------------|----------------|----------|------------------|------|
| Stickies + mount point | No | ✅ | ❌ | ❌ | `System Policy: Stickies deny(1) file-read-data ...` | Only 1 blank "Untitled" note left |
| Stickies + mount point (second run, retested with a different volume) | No | ✅ | ❌ | ❌ | Same as above | Consistently reproducible |
| WeChat + mount point | No | ✅ | ✅ | ✅ | First `rejected ... would require prompt`, then `granted by TCC` | Chat history complete; sending and receiving work normally |
| Maccy + mount point | No | ✅ | ✅ | ✅ | One preflight denial; actual access was not blocked | SQLite reads and writes normally |
| Xiaomi Interconnectivity (MAS) + mount point | No | ✅ | ✅ | ✅ | `AUTHREQ_PROMPTING` → `TCCDEvent: type=Create` | Works immediately once the user authorizes |
| Drive absent (empty directory) | — | ✅ | — | ✅ written locally | No deny | The app wrote its data into the local empty directory |
| Drive absent (`chmod 000` + `uchg`) | — | ✅ | — | ❌ | No deny | Silently shows a blank state, no error |
| Mount initiated by a script-based LaunchAgent | — | — | — | — | `TCC denied kTCCServiceSystemPolicyAppDataDetailed` + `file-mount` denial | Mount failed |
| fstab (`UUID=`) | Yes | — | — | — | `mount_apfs: volume could not be mounted` | Failed to resolve the UUID |
| fstab (`/dev/diskNsM`) | Yes | — | — | — | — | Mounts, but the device number is not stable |

## Raw Logs <a href="#raw-logs" id="raw-logs"></a>

### 1. Stickies: Silent Denial <a href="#_1-stickies-silent-denial" id="_1-stickies-silent-denial"></a>

```
2026-09-18 06:58:59.497 tccd  AUTHREQ_CTX: msgID=618.6014, function=TCCAccessRequest,
        service=kTCCServiceSystemPolicyRemovableVolumes, preflight=yes, query=1
2026-09-18 06:58:59.507 kernel (Sandbox) System Policy: Stickies(54845) deny(1) file-read-data
        /Users/<user>/Library/Containers/com.apple.Stickies/Data/Library/Stickies/.SavedStickiesState
2026-09-18 06:58:59.608 kernel (Sandbox) System Policy: Stickies(54845) deny(1) file-write-create
        /Users/<user>/Library/Containers/com.apple.Stickies/Data/Library/Stickies/C21E66AB-58DA-4CDF-838E-0EB30C65577B.rtfd
2026-09-18 06:58:59.623 kernel (Sandbox) System Policy: Stickies(54845) deny(1) file-read-data
        /Users/<user>/Library/Containers/com.apple.Stickies/Data/Library/Stickies
```

Note two things:

1. The reported path is the **path inside the container** (not `/Volumes/...`), which means the sandbox path check has already passed;
2. The source of the decision is `System Policy:` rather than `Sandbox:`, i.e. the TCC layer, and the service name is `kTCCServiceSystemPolicyRemovableVolumes`.

All requests were `preflight=yes` (a probing query that is not allowed to show a prompt), and the system denied them outright. How the app behaved: it showed only a single empty window (`1, 未命名`, i.e. one window titled "Untitled"); the two existing notes (on the volume: `.SavedStickiesState`, 2988 bytes, plus two `.rtfd`) were all invisible.

### 2. WeChat: Denied First, Then Authorized, Then Fully Normal <a href="#_2-wechat-denied-first-then-authorized-then-fully-normal" id="_2-wechat-denied-first-then-authorized-then-fully-normal"></a>

```
2026-09-18 06:51:57.504 sandboxd checking kTCCServiceSystemPolicyRemovableVolumes for WeChat
2026-09-18 06:51:57.518 kernel (Sandbox) sandboxd rejected approval request from WeChat for
        kTCCServiceSystemPolicyRemovableVolumes (.../com.tencent.xinWeChat/Data/Documents/xwechat_files):
        would require prompt
2026-09-18 06:52:03.570 sandboxd kTCCServiceSystemPolicyRemovableVolumes granted by TCC for WeChat
2026-09-18 06:52:04.409 sandboxd kTCCServiceSystemPolicyRemovableVolumes granted by TCC for WeChat
```

After authorization:

- WeChat launched fully, stayed logged in, and its chat list and history were complete;
- `lsof` showed 173 handles under `xwechat_files/wxid_...` and 15 under `all_users`, with the device number pointing to the external volume;
- The timestamps of `contact.db` / `contact.db-wal` / `contact_fts.db` on the volume kept updating with use (reads and writes really took place on the volume);
- **There was no file-level `deny` of any kind for `xwechat_files`.**

### 3. Xiaomi Interconnectivity (App Store App): An Explicit Authorization Prompt <a href="#_3-xiaomi-interconnectivity-app-store-app-an-explicit-authorization-prompt" id="_3-xiaomi-interconnectivity-app-store-app-an-explicit-authorization-prompt"></a>

```
2026-09-18 07:00:49.976 tccd AUTHREQ_CTX: service=kTCCServiceSystemPolicyRemovableVolumes, preflight=no
2026-09-18 07:00:50.001 tccd AUTHREQ_PROMPTING: service=kTCCServiceSystemPolicyRemovableVolumes,
        subject=Sub:{com.xiaomi.hyperConnect}
2026-09-18 07:00:53.814 tccd Publishing <TCCDEvent: type=Create,
        service=kTCCServiceSystemPolicyRemovableVolumes, identifier=com.xiaomi.hyperConnect>
```

After authorization, the app wrote new log files directly onto the volume:

```
小米互联服务_dist_camera_202609180700_055532_000.log
  dev=16777253（外置卷）   内置数据卷 dev=16777230
```

### 4. Mounting a Volume onto a Container Path Requires Full Disk Access <a href="#_4-mounting-a-volume-onto-a-container-path-requires-full-disk-access" id="_4-mounting-a-volume-onto-a-container-path-requires-full-disk-access"></a>

The same command, with only the caller changed, gives the opposite result:

```
# 脚本型 LaunchAgent 里跑（无 FDA）
2026-09-18 06:57:11.274 sandboxd checking kTCCServiceSystemPolicyAppDataDetailed on path "<private>",
        user interaction not allowed
2026-09-18 06:57:11.285 sandboxd TCC denied kTCCServiceSystemPolicyAppDataDetailed
2026-09-18 06:57:11.285 kernel (Sandbox) System Policy: diskutil(54274) deny(1) file-mount
        /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files
diskutil 输出：Volume on disk7s2 failed to mount

# 在已有 Full Disk Access 的进程里跑（同一台机器、同一条命令）
$ diskutil mount -mountPoint "$SUB" DB9ADB21-...     → exit 0，挂载成功
```

The corresponding TCC authorization records:

```
kTCCServiceSystemPolicyAllFiles | com.openai.codex   | auth_value=2   ← 已授权
kTCCServiceSystemPolicyAllFiles | com.apple.Terminal | auth_value=0   ← 未授权
```

### 5. Persisting via fstab <a href="#_5-persisting-via-fstab" id="_5-persisting-via-fstab"></a>

```
# 用 UUID=
$ sudo mount -a
mount_apfs: volume could not be mounted: Permission denied
mount: /Users/<user>/Library/Containers/.../xwechat_files failed with 66

# 改成设备节点
/dev/disk7s2 /Users/<user>/Library/Containers/.../xwechat_files apfs rw,nobrowse 0 0
$ sudo mount -a      → 挂载成功
```

## Conclusions <a href="#conclusions" id="conclusions"></a>

### (1) Is the Mount-Point Approach Viable for Sandboxed Apps? <a href="#_1-is-the-mount-point-approach-viable-for-sandboxed-apps" id="_1-is-the-mount-point-approach-viable-for-sandboxed-apps"></a>

**Viable, with preconditions.** Unlike a symbolic link, the mount point's path string lies inside the container, and the sandbox's container rule itself explicitly allows this:

```
;; /System/Library/Sandbox/Profiles/appsandbox-common.sb
(define (appsandbox-container-macos)
  (allow file-ioctl file-mknod file-revoke file-search file-mount file-unmount
         (container-subpath "")))
```

`container-subpath` / `container-regex` use the `resolving-*` family of matches (resolve symbolic links first, then compare the path string). After resolution, a mount point is still a container path, so the match succeeds.

**But the real gate is TCC**: with the data on an external volume, `kTCCServiceSystemPolicyRemovableVolumes` is triggered. Third-party apps can show a prompt and obtain authorization; platform apps only get a preflight denial.

### (2) The Exact Failure Mechanism <a href="#_2-the-exact-failure-mechanism" id="_2-the-exact-failure-mechanism"></a>

For apps like Stickies, the failure chain is:

```
应用读容器内的文件
  → 路径判定通过（挂载点在容器内）
  → 内核发现 vnode 在外置卷 → 要求 kTCCServiceSystemPolicyRemovableVolumes
  → sandboxd 以 preflight 询问，不能弹框
  → 返回 "would require prompt" 并拒绝
  → System Policy: deny(1) file-read-data
```

The app reads a file inside its container, so the path check passes. The kernel then finds that the vnode is on an external volume and requires `kTCCServiceSystemPolicyRemovableVolumes`. The sandboxd preflight request cannot display a prompt, so access is denied with "would require prompt".

What the app sees is an ordinary "file can't be read," with neither a prompt nor an error, so it treats this as a "first run": it shows a blank state and tries to create a new store in the container (which is also denied).

### (3) Safety Measures When the Drive Is Absent <a href="#_3-safety-measures-when-the-drive-is-absent" id="_3-safety-measures-when-the-drive-is-absent"></a>

| Approach | App launches | Result |
|------|------------|------|
| Empty directory | ✅ | The app writes its data into the **local empty directory**, diverging from the data on the volume |
| `chmod 000` + `chflags uchg` | ✅ | The app silently shows a blank state; no writes, no error |

Neither approach **reports an error**, and neither **prevents the app from launching**, so there is a risk that "the user thinks they are using the old data but is actually using a new copy." AppPorts uses the second approach, and refuses to mount again if local files appear in the mount point, so as not to cover up that data.

### (4) Observations That Don't Match Theory <a href="#_4-observations-that-don-t-match-theory" id="_4-observations-that-don-t-match-theory"></a>

1. **Platform apps and third-party apps behave differently.** Although all are sandboxed apps, Stickies got only preflight denials and no prompt, while WeChat / Maccy / Xiaomi all reached the authorization prompt. This difference is reproducible in the logs, but **why platform apps don't issue a request that can show a prompt was not established with solid evidence in this round**.
2. **About 6 seconds after its first denial, WeChat automatically switched to "granted by TCC".** No corresponding `AUTHREQ_PROMPTING` line was captured in the logs (it was captured in the Xiaomi run). The logs cannot prove whether an authorization prompt actually appeared this time and was allowed by the user; the authoritative wording of conclusion 1 is "platform apps only issue preflight requests that cannot show a prompt."
3. **Maccy had just one preflight denial and no deny afterwards, yet reads and writes worked normally.** This shows that the denied probe does not mean subsequent access was actually blocked.
4. **This page covers only macOS 27.** Supplementary verification on older systems is below.

## What This Means for AppPorts <a href="#what-this-means-for-appports" id="what-this-means-for-appports"></a>

- **Mount point + no re-signing** **is viable** for third-party sandboxed apps, and it has worked end to end on a real-world case like WeChat. This is something the symbolic-link approach cannot do.
- Platform apps (system apps under `/System/Applications`) fail silently; AppPorts does not migrate them anyway.
- **The process that performs the mount must have Full Disk Access**: an ordinary script-based LaunchAgent can't do it, so background remounting is done by AppPorts' own executable running with the `--mount-agent` argument, reusing the main app's authorization.
- **`/etc/fstab` is not used for persistence**: the `UUID=` form fails to resolve; with the `/dev/diskNsM` form, the device number changes with plug-in order, and at boot the mount is done by root, which is equally subject to TCC restrictions.
- The first time an app accesses the external volume, a **system authorization prompt** appears; this is a one-time step visible to the user.

## Later Additions <a href="#later-additions" id="later-additions"></a>

- **macOS 12 (2026-09-19)**: When the same procedure was run on macOS 12, `diskutil mount -mountPoint` was rejected by DiskArbitration (`kDAReturnNotPrivileged`: an ordinary user cannot mount a volume at a custom path). Retrying with administrator privileges succeeded, and the app could read the data on the volume normally, which shows that the macOS 12 sandbox profile likewise allows mount points inside the container. AppPorts therefore shows the system password prompt and retries when it hits this error; the login agent has no UI, so on such systems it cannot remount automatically. Which version between macOS 13 and 26 started allowing this has not yet been verified version by version.
- **Data safety when unplugging (2026-09-19)**: see [Experiment Log: Impact of Unplugging the Drive on APFS Volumes and Disk Images](unplug-test.md).

## Limits of the Experiment <a href="#limits-of-the-experiment" id="limits-of-the-experiment"></a>

- **No re-signing** at any point; all test apps kept their original signatures.
- Stickies is on the read-only system volume and AppPorts will not migrate it; it was used only to verify the sandbox mechanism itself.
- **The machine was not actually rebooted.** The boot-time behavior of fstab was simulated with `sudo mount -a`; the conclusions are based on the simulated results.
- `~/Library/Group Containers/` was not tested separately, but its path decisions work the same way as for `Containers`.
- The temporary APFS volumes, fstab lines, LaunchAgent and moved directories used for testing have all been restored.
