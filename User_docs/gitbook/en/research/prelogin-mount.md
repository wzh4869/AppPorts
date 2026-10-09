---
icon: "power-off"
description: "Review the procedure and results of mounting before login."
layout:
  width: "default"
  outline:
    visible: true
---

# Experiment Log: Pre-Login Mounting (Experiment A)

This page is the raw record of the third round of controlled experiments, following the [mount point experiment](sandbox-mountpoint.md). The question the experiment answers:

> Mount-migrated volumes have to be mounted onto container paths, and this is currently done by the **login agent** after login. Could it instead be done by a **root system-level daemon at boot (before login)**, eliminating once and for all the race where "an app opened right after boot reads an empty directory"?

Conclusion: **the "before login" goal cannot be achieved, but having a root daemon kick the user-side agent into running early is feasible.**

{% hint style="success" %}
**Key Findings**


1. **Before login is impossible**: this machine has FileVault enabled, and before login the path `~/Library/Containers/...` **does not exist at all** (the Data volume waits for the user to unlock it). So the earliest moment to act is the moment of unlocking, not the moment of booting.
2. **A system-domain daemon cannot mount by itself**: a root process does not automatically have Full Disk Access, and `diskutil mount -mountPoint` is denied by TCC (`kTCCServiceSystemPolicyAppDataDetailed`), just like an ordinary user process. The same command succeeds from a root shell inside the user session; the difference lies in the TCC identity, not the uid.
3. **But the daemon can limit itself to "calling someone in"**: without any TCC authorization it can run `launchctl kickstart gui/501/...` to bring up the FDA-authorized AppPorts agent immediately (measured < 1 second), without touching the container data itself.
4. Along the way we found that the real source of the race is not a slow agent, but that **launchd puts the login agent in the "speculative launch" queue**: on the previous boot, **17.6 seconds** passed between login completion and the agent being spawned; the agent's own startup took only about 2 seconds, and mounting less than 1 second.
{% endhint %}

## Environment <a href="#environment" id="environment"></a>

| Item | Value |
|------|-----|
| System | macOS 27.0 (26A428), Darwin 27.0.0, arm64 (T8132) |
| FileVault | **On** (`fdesetup status` → `FileVault is On.`; Data volume `FileVault: Yes (Unlocked)`) |
| External drive | `/Volumes/hano` — APFS container `disk7` (not encrypted) |
| Container volume 1 | `disk7s2` / `BEAF241C-…` → `…/Data/Documents/xwechat_files/wxid_1zxh3e4ctfeh22_9c44` |
| Container volume 2 | `disk7s3` / `FD3DDDE6-…` → `…/Data/Library/Application Support/com.tencent.xinWeChat` |
| Existing TCC grants | `com.shimoko.AppPorts` → `kTCCServiceSystemPolicyAllFiles` (FDA, allowed) |
| Throughout | No `codesign --sign` was run at any point, and the mount records were not modified |

## Probe 1: Can a System-Domain Root Daemon Mount onto a Container Path? <a href="#probe-1-can-a-system-domain-root-daemon-mount-onto-a-container-path" id="probe-1-can-a-system-domain-root-daemon-mount-onto-a-container-path"></a>

A temporary LaunchDaemon (`com.appports.probe.mount`) ran a `/bin/sh` script in the **system domain**, with the goal of mounting a 64 MB APFS test image at
`~/Library/Containers/com.apple.TextEdit/Data/ap-probe-target`:

```text
[探测日志] === 触发 2026-09-22 02:45:09 ===
[探测日志] uid=0  launchctl-manager=System
[探测日志] --- 目标路径可达性 ---
[探测日志] drwxr-xr-x@ 2 wangheng  staff  64 Sep 22 02:44 …/ap-probe-target
[探测日志] --- 执行 diskutil mount -mountPoint ---
[探测日志] Volume on disk5s1 failed to mount
[探测日志] diskutil-exit=1
[探测日志] --- 目标路径内容（能读说明挂上了）---
[探测日志] ls: …/ap-probe-target: Operation not permitted
```

(The probe script's output is quoted verbatim. `探测日志` = probe log; the section markers read "triggered", "target path reachability", "run diskutil mount -mountPoint", and "target path contents (readable means mounted)".)

Capturing `log stream` at the same time yields the raw TCC decision (`<private>` is the system's redaction; compare with the next section):

```text
2026-09-22 02:45:10.080 Df tccd … one instance of XPC forwardMessage … (service=kTCCServiceSystemPolicyAppDataDetailed, requestor=com.apple.sandboxd, target_pid=9204, target_id=com.apple.sh, auid=0)
2026-09-22 02:45:10.082 Df sandboxd[429:190b1] [com.apple.sandbox:sandcastle] checking kTCCServiceSystemPolicyAppDataDetailed on path "<private>", user interaction not allowed
2026-09-22 02:45:10.082 Df sandboxd[429:190b1] [com.apple.sandbox:sandcastle] TCC denied kTCCServiceSystemPolicyAppDataDetailed for <private>
2026-09-22 02:45:10.082 E  kernel[0:18c57] (Sandbox) System Policy: diskutil(9215) deny(1) file-mount /Users/wangheng/Library/Containers/com.apple.TextEdit/Data/ap-probe-target
2026-09-22 02:45:10.165 E  kernel[0:1943d] (Sandbox) System Policy: ls(9223) deny(1) file-read-data /Users/wangheng/Library/Containers/com.apple.TextEdit/Data/ap-probe-target
```

Note that `auid=0` (root) is denied just the same, and with `user interaction not allowed`: a daemon has no session, so the system does not even ask; it denies outright.

## Probe 2: The Same Command Succeeds in a Different Context <a href="#probe-2-the-same-command-succeeds-in-a-different-context" id="probe-2-the-same-command-succeeds-in-a-different-context"></a>

Same root identity, but escalated and run from **a terminal inside the user session**:

```console
$ sudo diskutil mount -mountPoint /Users/wangheng/Library/Containers/com.apple.TextEdit/Data/ap-probe-target /dev/disk5s1
Volume APProbe on /dev/disk5s1 mounted        # ← 成功
$ sudo ls -la /Users/wangheng/Library/Containers/com.apple.TextEdit/Data/ap-probe-target
total 0                                        # ← 能读
```

The control (root mounting onto a path not protected by TCC) also succeeded on the first try, which shows that the test image itself is fine:

```console
$ sudo diskutil mount -mountPoint /tmp/ap-probe/mp-root /dev/disk5s1
Volume APProbe on /dev/disk5s1 mounted
```

Conclusion: **whether a process can mount onto a container path depends on its TCC identity, not on its uid.** FDA grants are recorded against the code-signing identity. This machine's TCC database already contains non-GUI, daemon-style binaries that hold FDA (`/usr/sbin/smbd`, `/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper`, `siriactionsd`, `auth_value=2`), so the "daemon + FDA" route is not ruled out by the system; the daemon would simply need to be granted FDA.

## Probe 3: FileVault Means "Before Login" Simply Doesn't Exist <a href="#probe-3-filevault-means-before-login-simply-doesn-t-exist" id="probe-3-filevault-means-before-login-simply-doesn-t-exist"></a>

```console
$ fdesetup status
FileVault is On.
$ diskutil apfs list | grep -A2 "disk2s5"
|   +-> Volume disk2s5 D4B13B11-… 
|   |   APFS Volume Disk (Role):   disk2s5 (Data)
|   |   FileVault:                 Yes (Unlocked)      # ← 开机时是锁着的，"Unlocked" 是登录后
```

`/Users/wangheng` lives on the Data volume. Before login that volume is not unlocked, so `~/Library/Containers/...` does not exist, and **no process (whether root or a daemon) can mount a volume onto a path that does not exist yet**. The lower time bound for option A is therefore "the moment the user unlocks," not "the moment of boot."

## Probe 4: A Daemon That Only "Calls In" the Agent Works <a href="#probe-4-a-daemon-that-only-calls-in-the-agent-works" id="probe-4-a-daemon-that-only-calls-in-the-agent-works"></a>

The root daemon issues a kickstart (without touching the container itself):

```console
$ # 由系统域守护进程执行
$ launchctl kickstart gui/501/com.shimoko.AppPorts.container-mount
$ echo $?
0
```

An agent run immediately appears in AppPorts' own log:

```text
[2026-09-22 02:46:12] [INFO] [session:CA65AB0F] [pid:9519] 容器卷自动挂载代理启动
[2026-09-22 02:46:12] [INFO] [session:CA65AB0F] [pid:9519] 自动挂载代理结果   mount_point: …/wxid_1zxh3e4ctfeh22_9c44   state: alreadyMounted
[2026-09-22 02:46:12] [INFO] [session:CA65AB0F] [pid:9519] 自动挂载代理结果   mount_point: …/Application Support/com.tencent.xinWeChat   state: alreadyMounted
[2026-09-22 02:46:12] [INFO] [session:CA65AB0F] [pid:9519] 容器卷自动挂载代理退出
```

(AppPorts' log messages are in Chinese and are quoted verbatim: agent started → per-mount-point result → agent exited.)

One detail: `launchctl kickstart -k` (with `-k` to force a restart) **is throttled by launchd when called repeatedly within a short time**, and the command itself blocks for anywhere from ten-odd seconds to several tens of seconds before returning; `kickstart` without `-k` does not. We ran into this during the experiment, so the probe script was later changed to a non-blocking call + polling for the mount result.

## The Actual Timeline of the Previous Boot (Where the Race Comes From) <a href="#the-actual-timeline-of-the-previous-boot-where-the-race-comes-from" id="the-actual-timeline-of-the-previous-boot-where-the-race-comes-from"></a>

launchd's own records from `log show`; pid 801 is the mount agent:

```text
2026-09-22 02:22:43                    开机
2026-09-22 02:22:50  storagekitd        macOS 自己把两个容器卷挂到 /Volumes/AppPorts-…
2026-09-22 02:23:10  loginwindow        loginDone（登录完成）
2026-09-22 02:23:10.962 launchd          pending spawn, domain in on-demand-only mode: com.shimoko.AppPorts.container-mount
2026-09-22 02:23:13  ps                WeChat 被登录项拉起
2026-09-22 02:23:28.523 launchd         Successfully spawned AppPorts[801] because speculative   ← 登录后 17.6 秒
2026-09-22 02:23:32.512 AppPorts         容器卷自动挂载代理启动                                    ← 进程初始化约 2 秒
2026-09-22 02:23:37 → 02:23:41 AppPorts   两个卷先卸后挂，挂回容器路径
```

The breakdown of the cost is clear: **18 seconds queued in launchd, 2 seconds in AppPorts' own startup, 4 seconds mounting the two volumes**. WeChat was fine this time only because it read its data relatively late after starting (it started at 02:23:13, the mounts were done only at 02:23:41, still within an acceptable range). An app that starts quickly and reads its data at startup would read an empty directory.

## Conclusions of the Controlled Probes <a href="#conclusions-of-the-controlled-probes" id="conclusions-of-the-controlled-probes"></a>

| Form | Feasibility | Basis |
|------|--------|------|
| Root daemon mounts **by itself, before login** | Not feasible | FileVault: the container path does not exist before login (Probe 3) |
| Root daemon mounts **by itself** (after unlock) | Requires a separate FDA grant for the daemon | Probe 1's `deny(1) file-mount`; TCC identity is determined by the code signature |
| Root daemon **kickstarts the user agent** | Feasible, no new authorization needed | Probe 4; the daemon only calls `launchctl`, and the mount itself is still performed by AppPorts, which has FDA |
| Shorten the existing agent's startup delay | Two directions; see "Boot Measurement" below | Partly stuck on launchd queuing traditional agents behind login items, partly the system being busy overall after login |

One more form, **not adopted**, is worth recording: having the daemon run AppPorts' own executable directly (`--mount-agent`). FDA is recorded against the code-signing identity, and `com.shimoko.AppPorts` already has FDA on this machine, so in theory the permission hurdle is cleared. In practice, however, under a root identity AppPorts resolves the home directory to `/var/root` (it created a new `~/Library/Application Support/AppPorts/` there, read an empty mount record, and exited without doing anything). This form would therefore first require the program to support explicitly specifying the user directory, i.e. it is an approach that requires code changes.

## Boot Measurement (the 2026-09-22 05:48:08 Boot) <a href="#boot-measurement-the-2026-09-22-05-48-08-boot" id="boot-measurement-the-2026-09-22-05-48-08-boot"></a>

The probe ran persistently as a LaunchDaemon (root, system domain, `RunAtLoad`), polling every 1 second after boot and recording "when the container path became visible," "whether the kickstart succeeded," and "when the two volumes were mounted back onto the container paths." Raw log: `sudo cat /var/log/ap-boot-probe.log`.

| Time | Event | Source |
|------|------|------|
| 05:48:08 | Boot | `kern.boottime` |
| 05:48:17 | macOS mounts the three external volumes at `/Volumes` (before login) | kernel apfs `mount-complete` |
| 05:48:47.96 | **Only now is the probe daemon started** (40 seconds after boot) | Probe log |
| 05:48:48.6 | Container path visible (Data volume unlocked) | Probe log |
| 05:48:50.1 | Probe kickstart → `Could not find domain for user gui: 501` | `/var/log/ap-kickstart.out` |
| 05:48:50.33 | **`loginDone` (login complete)** | loginwindow log |
| 05:48:54 | WeChat launched by login items; the container path is still an empty directory at this point | `ps -o lstart` |
| 05:49:15 | **Only now is the AppPorts agent spawned by launchd** (pid 916, 24.7 seconds after login) | AppPorts log |
| 05:49:24 → 05:49:27 | Both volumes unmounted, then remounted; done | AppPorts log (`diskutil` TRACE, line by line) |

Three conclusions:

1. **"Before login" is a fantasy**: even the root daemon itself was scheduled by launchd to run only 40 seconds after boot, 31 seconds later than macOS mounted the external volumes; at the moment it started running, the Data volume had just been unlocked and the container path had just become visible.
2. **The kickstart missed by only 0.2 seconds**: the probe issued the kickstart at 05:48:50.1, and `loginDone` was at 05:48:50.33. The session domain had not quite been set up yet, so it got `Could not find domain for user gui: 501`. At the time the probe tried only once and then went into polling, without retrying, so it could not demonstrate the later benefit. **Had it retried every second, it could have kicked the agent up within one second of `loginDone`, about 21 seconds earlier than the actual 05:49:15, and also before WeChat (05:48:54) read its data.**
3. **The agent itself was also pushed back 24.7 seconds by launchd**: `loginDone` was at 05:48:50, and the agent was spawned only at 05:49:15, whereas a login item like WeChat was up within 3.7 seconds. The reason is that for a while after login the user domain is in on-demand-only mode, and "can wait" jobs such as `RunAtLoad` are deferred (verbatim from the previous boot: `pending spawn, domain in on-demand-only mode` → 17.6 seconds later, `Successfully spawned … because speculative`).
4. The agent was brought up at 05:49:15 but emitted its first `diskutil` output only at 05:49:24 (a 9-second gap with no commands at all in the log), and then finished mounting at 05:49:27. At that same moment the system was busy wrapping up login (storagekitd probing volumes, third-party monitoring tools scanning capacity), and each of the agent's `diskutil` calls took about 1 second at the time, whereas the same calls tested at idle now take only 0.1–0.2 seconds. This stretch is the system being busy overall after login, not some command being written wrong.

A comparison recorded along the way: WeChat started at 05:48:54 and its data was mounted back only at 05:49:27, so for the 33 seconds in between it was reading an empty directory. But it did not write anything locally (otherwise the mount would have failed with "挂载点不为空", meaning "mount point not empty"), and once the data was mounted back it recovered on its own: the conversation list, chat history, and new messages after 05:49 were all normal. The real safety net is this: **the mount point always stays empty, so the data cannot diverge.**

### Verdict on Option A <a href="#verdict-on-option-a" id="verdict-on-option-a"></a>

**The goal of "mounting before login" is dropped** (FileVault makes it impossible), but **the goal of "not waiting in launchd's queue and kicking the agent up as early as possible" is very valuable: about 20 seconds**, which is the bulk of the entire current race window.

| Form | Verdict |
|------|------|
| Daemon mounts before login | Not feasible (FileVault) |
| Daemon mounts by itself (after unlock) | Needs an extra FDA grant, and is no earlier than the user agent |
| Daemon kickstarts the user agent (**retries required**) | Mechanism verified (a kickstart makes the agent start within the same second); benefit about 20 seconds; cost: a system-level daemon + a one-time administrator installation |
| Keep the agent itself from being queued | ✅ **Measured to work**: after adding `KeepAlive { SuccessfulExit: false }` and removing `ProcessType: Background`, the agent went from "starting 24.7 seconds after login" to "starting 4.6 seconds after login"; see the "Reboot Measurement" section below |

Another route worth trying, one that does not install a system component: switch the agent from a "traditional agent in `~/Library/LaunchAgents`" to an `SMAppService` login item, so that launchd brings it up in the same batch as login items like WeChat. The cost is that the plist has to go into `Contents/Library/LaunchAgents/` (changes to the Xcode project + re-signing and redeployment); the benefit would likewise be those 20 seconds, but it would not necessarily start as early as the login items. This has not been measured.

## Post-Reboot Self-Check (Verifying Whether `KeepAlive` Really Makes the Agent Start Earlier) <a href="#post-reboot-self-check-verifying-whether-keepalive-really-makes-the-agent-start-earlier" id="post-reboot-self-check-verifying-whether-keepalive-really-makes-the-agent-start-earlier"></a>

The agent definition currently on the machine (`~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist`):

```xml
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>LimitLoadToSessionType</key><array><string>Aqua</string></array>
<key>WatchPaths</key><array><string>/Volumes</string></array>
```

Compared with the definition before the change: `KeepAlive` was added and `ProcessType = Background` was removed (that setting amounts to actively telling launchd "I'm in no hurry," the opposite of what we want). `SuccessfulExit: false` inside `KeepAlive` means "**restart only on failure**". The agent's implementation ends with `exit(0)` whether mounting succeeds or fails (failures are only logged), so no restart loop can occur here: the only effect of `KeepAlive` is to make launchd treat this job as "needs to run" instead of queuing it at login.

After rebooting, run this script; it lays out "boot → external volumes mounted → login complete → agent spawned → WeChat started → volumes mounted back onto the container paths" in chronological order:

```bash
bash ~/sandbox-test-backup/check-boot-timeline.sh
```

| What you see | Verdict |
|------|------|
| Agent spawn time ≈ `loginDone` (1–3 seconds apart) | `KeepAlive` **works**: about 20 seconds earlier than the previous 17–25 seconds, starting in the same batch as WeChat; the race window is essentially closed |
| Agent spawn time ≈ `loginDone` + 17 seconds or more | `KeepAlive` **does not work**; launchd still queues RunAtLoad jobs → switch to the kickstart daemon with retries |

While at it, confirm one more thing: `runs` in `launchctl print gui/501/com.shimoko.AppPorts.container-mount` should not keep climbing on its own (if it does, `KeepAlive` has been interpreted as "always restart").

Two prerequisite facts (already verified, independent of the reboot):

- The deployed bundle `~/Desktop/test/AppPorts-2026-09-21-fix/AppPorts.app` has been replaced with a Release build that contains this change (2026-09-22 06:01). Its signing identity, TeamIdentifier and entitlements match the old bundle item by item, and `codesign --verify --deep --strict` passes, so the TCC Full Disk Access grant carries over unchanged (the TCC database stores a requirement anchored to the certificate CN, not a cdhash).
- The new binary was run once on its own as a background agent (`launchctl kickstart`). Verbatim log: `容器卷自动挂载代理启动` (agent started) → two `state: alreadyMounted` lines → `容器卷自动挂载代理退出` (agent exited), `last exit code = 0`. `alreadyMounted` can only be determined by reading the container path, so this also proves that the new bundle still has FDA.

## Reboot Measurement (the 2026-09-22 06:35:47 Boot) <a href="#reboot-measurement-the-2026-09-22-06-35-47-boot" id="reboot-measurement-the-2026-09-22-06-35-47-boot"></a>

After installing the `KeepAlive` definition, the machine was rebooted once and the timeline was taken with `bash ~/sandbox-test-backup/check-boot-timeline.sh`:

| Time | Event | Source |
|------|------|------|
| 06:35:47 | Boot | `kern.boottime` |
| 06:36:20.372 | **`loginDone` (login complete)** | loginwindow |
| 06:36:21.276 / .301 / .327 | macOS mounts the three external volumes at `/Volumes` (1 second after login) | kernel apfs `mount-complete` |
| 06:36:22.503 | launchd: `pending spawn, domain in on-demand-only mode` | launchd |
| 06:36:25 | **Agent starts (pid 905)** = login complete + 4.6 seconds; WeChat was brought up by login items in the same second (pid 956) | AppPorts log / `ps -o lstart` |
| 06:36:33 | The first `diskutil info` only returns now (this one call took about 8 seconds) | AppPorts TRACE |
| 06:36:38 | First volume mounted onto its container path, `state: mounted` | AppPorts log |
| 06:36:39 | Second volume mounted onto its container path, `state: mounted`; agent exits, `exit 0` | AppPorts log |
| After 06:36:39 | `runs = 1`; KeepAlive did not restart the agent over and over; the few runs that appeared afterwards were all no-op runs triggered by WatchPaths (see the next section) | `launchctl print` |

Same machine, same two volumes, compared with the round before the change (the 05:48 one):

| | Before the change (booted 05:48:08) | After the change (booted 06:35:47) |
|---|---|---|
| Agent spawned by launchd | `loginDone` + 24.7 s | **`loginDone` + 4.6 s** |
| Both volumes mounted back onto the container paths | `loginDone` + 37 s | **`loginDone` + 18 s** |
| launchd's complaint before spawning the agent | `pending spawn, domain in on-demand-only mode` → only 17.6 s later `Successfully spawned … because speculative` | The same message appears, but the wait was only about 2.5 s |

**Conclusion: `KeepAlive` works, with a net gain of about 19 seconds**; the problem of "the agent being queued behind login items" is closed.

A window still remains: WeChat came up at 06:36:25 and read an empty directory, and the data was mounted back only at 06:36:38/39, about 13 seconds later. These 13 seconds are not queuing; they are "a freshly logged-in system being busy in itself": the first `diskutil info` took about 8 seconds (load average 24 at the time), and the two "unmount + mount" cycles took up the rest. On the same machine at idle, the same command takes only 0.1–0.2 seconds. WeChat was again fine this time: a mount point must be empty for a volume to be mounted on it, and both volumes did get mounted, which shows that WeChat did not write anything locally during those 13 seconds.

### Side Finding: `WatchPaths` Matches by Subtree, Causing Too Many No-Op Runs (Present Before the Change) <a href="#side-finding-watchpaths-matches-by-subtree-causing-too-many-no-op-runs-present-before-the-change" id="side-finding-watchpaths-matches-by-subtree-causing-too-many-no-op-runs-present-before-the-change"></a>

The real definition in `launchctl print gui/501/com.shimoko.AppPorts.container-mount`:

```
event triggers = {
	com.apple.launchd.WatchPaths => {
		stream = com.apple.fsevents.matching      ← 不是目录监听，是 FSEvents 按路径前缀匹配
		descriptor = { "WatchPaths" => [ 0 = "/Volumes" ] }
	}
}
```

`stream = com.apple.fsevents.matching` means that any file change **within the `/Volumes` subtree** triggers the agent, including any write on the external drive `/Volumes/hano`. Measured: in one 5-minute stretch the agent was brought up 4 times (06:44:41, 06:45:29, 06:48:03, 06:48:23), while over the same period a kqueue watch on the `/Volumes` directory itself saw **0 changes**; in another 4-minute stretch both counts were 0. All of these no-op runs return `alreadyMounted` directly, without calling `diskutil` or touching the disk. The no-op runs themselves are left as they are (automatic remounting after the drive is plugged in depends on them), but the logging has been compacted: **one no-op round writes only 3 lines**:

```
容器卷自动挂载代理启动
容器卷自动挂载代理结束：2 个挂载点都已在位，无操作     ← TRACE
容器卷自动挂载代理退出
```

(Verbatim AppPorts log: agent started → agent finished: both mount points already in place, no action → agent exited.)

The line-by-line details are written only when a volume was actually acted on (`mounted`), a volume could not be read (`unavailable`), or a mount failed (`failed`). Before this change, one no-op round wrote 9 lines, which at the frequency measured above could eat up nearly 1 MB a day.

This was not introduced by this change (before the change, around 02:4x, there was also a record of 23 runs in 20 minutes).

## Follow-up Hardening: Tying "Try Again" to Real Events on `/Volumes` (2026-09-23) <a href="#follow-up-hardening-tying-try-again-to-real-events-on-volumes-2026-09-23" id="follow-up-hardening-tying-try-again-to-real-events-on-volumes-2026-09-23"></a>

### What Prompted It <a href="#what-prompted-it" id="what-prompted-it"></a>

On two boots, 2026-09-21 11:10 and 09-23 06:00, the agent log both times read `state: failed("挂载后校验失败，该路径不是挂载点：…")` (post-mount verification failed; the path is not a mount point: …), and the user then saw "what was mounted before shows 0 bytes" and "WeChat isn't working properly."

### Root Cause: `diskutil mount -mountPoint` "Pretends to Succeed" <a href="#root-cause-diskutil-mount-mountpoint-pretends-to-succeed" id="root-cause-diskutil-mount-mountpoint-pretends-to-succeed"></a>

When the **volume is already mounted**, `diskutil mount -mountPoint <路径> <卷>` does not report an error; instead it ignores the mount point argument, simply prints `mounted`, and returns 0. At boot or plug-in, macOS itself first automounts the volume at `/Volumes/AppPorts-…`. At the moment the agent reads `diskutil info`, that automount may not have finished yet (`MountPoint` is empty), so the "no need to unmount first" check holds, and the command then turns into a no-op: the command succeeds, the mount point is empty, the verification (a `statfs` check) faithfully detects this and reports failure, and the agent then gives up.

Reproduced with a temporary APFS image (the volume already mounted at `/Volumes/APProbeVol`, then a different mount point specified):

```
$ diskutil info -plist /dev/disk7s1 | plutil -extract MountPoint raw -
/Volumes/APProbeVol
$ diskutil mount -mountPoint /tmp/ap-probe/mp /dev/disk7s1
Volume APProbeVol on /dev/disk7s1 mounted          # exit=0
$ diskutil info -plist /dev/disk7s1 | plutil -extract MountPoint raw -
/Volumes/APProbeVol                               # 挂载点没变
$ mount | grep APProbeVol
/dev/disk7s1 on /Volumes/APProbeVol (apfs, local, nodev, nosuid, journaled, noowners, mounted by wangheng)
```

This also confirmed something: the verification logic itself is fine, and its verdict was true; it detected that the volume was not at the target path. What was missing was **retrying after that detection**, instead of calling it a day.

### Events on `/Volumes` Can Be Caught Within 0.1 Seconds <a href="#events-on-volumes-can-be-caught-within-0-1-seconds" id="events-on-volumes-can-be-caught-within-0-1-seconds"></a>

Tested with a temporary APFS image, using kqueue to watch `/Volumes` (`NOTE_WRITE|DELETE|EXTEND|RENAME|LINK|ATTRIB`):

```
1.12s -> attach 开始
1.24s 收到事件 fflags=0x12     ← 比 hdiutil 自己返回（1.27s）还早
1.26s 收到事件 fflags=0x2
1.27s -> attach 退出码 0
```

(Test output quoted verbatim: `attach 开始` = attach started, `收到事件` = event received, `attach 退出码 0` = attach exit code 0.)

Both mounting and unmounting modify the `/Volumes` directory itself, and the event arrives within 120 ms; `fflags=0x2` (NOTE_DELETE) is the second notification from the same burst (it also shows up in chains when 6 volumes are plugged or unplugged together). So "waiting for the volume to appear" can be implemented as **waiting for a directory event** rather than with a timer: after an event, leave a 1-second quiet window before acting (the event arrives about 100 ms before the volume is usable), and count a burst as a single change.

### Changes <a href="#changes" id="changes"></a>

| Location | Change |
|------|------|
| `DiskUtility.isMountPoint` | Path comparison now also applies `realpath()`. On macOS 27, `URL.resolvingSymlinksInPath()` **does not resolve `/tmp`** (it returns `/tmp/...`), while `statfs` gives `/private/tmp/...`; comparing only these two spellings would judge a volume that is plainly mounted as "not a mount point" |
| `ContainerVolumeMigrator.mountVolume` | Verify after mounting; if the volume did not land in place, look up again where the volume is mounted, unmount it from there and mount it again, up to 3 rounds (0.5 seconds between rounds). Verification uses `statfs` as the primary criterion, with `diskutil`'s mount point as the authoritative fallback |
| `VolumeChangeMonitor` (new) | A kqueue-based waiter for directory changes, with a quiet window and reopening after the inode changes |
| `ContainerRemountLoop` (new) | Retry policy: retry only when an event arrives, with a 20-second fallback recheck when no event comes; total window 180 seconds, at most 20 rounds |
| `ContainerMountAgentInstaller` | The agent now does "take lock → try one round → release lock → wait for event → try again", **without holding the lock while waiting for the volume**; the first round still waits the full 120 seconds as before, and each later round waits only 10 seconds |
| `ContainerVolumeMigrator.knownMountPoint` | Before mounting, first try a zero-cost fast path: `statfs` to check whether `/Volumes/<卷名>` is a mount point + read the volume-root marker to confirm it is our own volume (microseconds); only if it cannot be recognized does it fall back to `diskutil info` |

### Real-Machine Verification (2026-09-23 08:04, WeChat Volumes Unaffected) <a href="#real-machine-verification-2026-09-23-08-04-wechat-volumes-unaffected" id="real-machine-verification-2026-09-23-08-04-wechat-volumes-unaffected"></a>

We created a temporary APFS volume + a temporary mount record (the original `container-mounts.plist` was backed up), ejected the volume, and then kickstarted the agent:

```
[08:04:18] 容器卷自动挂载代理启动
[08:04:18] 开始监听目录变化        path: /Volumes  settle_seconds: 1.0
[08:04:18] 还有挂载点没就位，开始等外置卷出现    pending: 1  window_seconds: 180
[08:04:18] 等待中的挂载点          state: unavailable
[08:04:28] 等到目录变化，重试挂载   cycle: 1  flags: 0x12  waited_seconds: 9.7   ← 事件到达
[08:04:28] 容器卷已挂在其它位置，先卸载再挂到容器路径  current_mount_point: /Volumes/APE2E
[08:04:29] 容器卷已挂载            mount_point: /tmp/ap-e2e/mountpoint
[08:04:29] 自动挂载代理重试统计    cycles: 2  waited_for_volume: true  reason: settled
[08:04:29] 容器卷自动挂载代理退出
```

In the same run, the two WeChat volumes reported `alreadyMounted` and were not affected by this round. After wrapping up, the agent was run once more: `容器卷自动挂载代理结束：2 个挂载点都已在位，无操作` (agent finished: both mount points already in place, no action), back to the normal state.

Another control set: with the volume pre-mounted at `/Volumes` before letting the agent run (one try at each of seven delays: 0.6/0.8/1.0/1.2/1.4/1.6/1.8 seconds), all seven runs correctly ended up at the target path (6 of them via "unmount first, then mount"). **The "verification failed → retry" branch was not reproduced on the real machine**: its trigger window is the few tens of milliseconds "between reading `MountPoint` and the volume actually being mounted," while the agent takes around a second from startup to reading `info`, so it is hard to hit on purpose (historically, the two occurrences happened naturally). This branch is covered by unit tests with a fake runner (`reclaimsVolumeFromForeignAutomount`, `failsAfterMountAttempts`).

### Second Round of Hardening (2026-09-23 14:4x): Skipping the 9-Second `diskutil` Query at Boot <a href="#second-round-of-hardening-2026-09-23-14-4x-skipping-the-9-second-diskutil-query-at-boot" id="second-round-of-hardening-2026-09-23-14-4x-skipping-the-9-second-diskutil-query-at-boot"></a>

The timeline of the 2026-09-23 13:56 boot (the first reboot after the change) is as follows. The empty-directory window was still about 15 seconds, but its causes no longer include "the agent being queued":

| Time | Event |
|------|------|
| 13:55:52 (boot +7s) | The system automounts the three volumes at `/Volumes` |
| 13:56:17.4 | Login complete |
| 13:56:21.4 | WeChat is brought up and reads an empty directory |
| 13:56:22 (login complete +4.6s) | Agent starts (`KeepAlive` still effective) |
| 13:56:23 → 13:56:32 | **The first `diskutil info` took 9 seconds** (the system is busy after login) |
| 13:56:35 → 13:56:37 | Unmount the volumes the system mounted at `/Volumes`, then mount them onto the container paths |

Broken down: 4.6 seconds (agent startup) + 9 seconds (`diskutil info`) + about 4 seconds (unmounting the system's mount points) + under 1 second (mounting).

The original purpose of that 9-second query was "to find out in one go whether the volume is online + where it is currently mounted." But in the boot scenario the volume is always mounted by the system at `/Volumes/<卷名>`, and the volume name is stored in the record. One look at that path with `statfs`, plus one read of the volume-root marker (`volumeUUID` in `.appports-mount-metadata.plist`), is enough to confirm that it is our own volume, and both local calls take microseconds. If it cannot be recognized (the volume was renamed by the system, the marker is missing, the volume is not mounted at all), it falls back to the `diskutil` query, with unchanged behavior. On the safety side, the UUID in the marker must match the record before that mount point is unmounted, to avoid mistakenly unmounting some other volume with the same name.

Real-machine verification (temporary APFS volume + temporary record; WeChat volumes unaffected):

```
[14:42:59] 容器卷自动挂载代理启动
[14:42:59] 卷已由系统挂在自动挂载点，直接切换   current_mount_point: /Volumes/AppPorts-e2e-fast
[14:42:59] 容器卷已挂在其它位置，先卸载再挂到容器路径
[14:42:59] diskutil unmount /Volumes/AppPorts-e2e-fast      → status 0
[14:43:00] diskutil mount -mountPoint /tmp/ap-fast/mountpoint DA3C9BD2-…  → status 0
[14:43:00] 容器卷已挂载
[14:43:00] 容器卷自动挂载代理退出
```

The whole round involved **no `diskutil info` at all**, only the two commands `unmount` + `mount`, finishing in about 1 second; in the same run, the two WeChat volumes reported `alreadyMounted`. Three new test cases guard this path (fast path hit, falling back to the query when the marker does not match, falling back to the query when the volume is not mounted).

## Appendix: Probe Scripts (Removed After the Measurements) <a href="#appendix-probe-scripts-removed-after-the-measurements" id="appendix-probe-scripts-removed-after-the-measurements"></a>

```bash
# 当时装过的两个文件（实验结束后已删除，别把它们留在机器上）
/Library/LaunchDaemons/com.appports.probe.boot.plist      # RunAtLoad，调下面这个脚本
/Library/PrivilegedHelperTools/ap-boot-probe.sh           # 副本留在 ~/sandbox-test-backup/ap-boot-probe.sh
# 脚本逻辑：等容器路径出现 → 非阻塞 kickstart → 轮询两个卷是否挂回容器路径
# 原始输出（保留作证据，root 可读）
/var/log/ap-boot-probe.log
/var/log/ap-kickstart.out
```

```bash
# 读原始记录
sudo cat /var/log/ap-boot-probe.log
```

## Related Docs <a href="#related-docs" id="related-docs"></a>

- [Mount Migration](../datamigrae/mount-migration.md)
- [Experiment Log: Sandboxed Apps + Mount Points](sandbox-mountpoint.md)
- [Experiment Log: Sandboxed Apps + Symbolic Links](sandbox-symlink.md)
