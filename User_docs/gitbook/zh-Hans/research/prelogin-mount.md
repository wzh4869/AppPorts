---
icon: "power-off"
description: "查看登录前挂载的实验步骤与结果。"
layout:
  width: "default"
  outline:
    visible: true
---

# 实验记录：开机前挂载（A 实验）

本文是继[挂载点实验](sandbox-mountpoint.md)之后的第三轮受控实验的原始记录。实验回答的问题是：

> 挂载迁移的卷要挂到容器路径上，而这件事目前由**登录代理**在登录后做。能不能改由 **root 系统级守护进程在开机时（登录前）** 就做完，彻底消掉「开机立刻打开应用读到空目录」的竞速？

结论：**「登录前」这个目标是做不到的，但让 root 守护进程把用户侧代理提前踢起来是可行的。**

{% hint style="success" %}
**一句话结论**


1. **登录前不可能**：本机开了 FileVault，登录前 `~/Library/Containers/...` 这条路径**根本不存在**（Data 卷要等用户解锁）。所以最早可行动的时机是解锁那一刻，不是开机那一刻。
2. **系统域守护进程自己挂不了**：root 进程不自动拥有 Full Disk Access，`diskutil mount -mountPoint` 会被 TCC 拒（`kTCCServiceSystemPolicyAppDataDetailed`），和普通用户进程一样。同样的命令在用户会话里的 root shell 下就能成功，差别在 TCC 身份不在 uid。
3. **但守护进程可以只做「喊人」**：它不需要任何 TCC 授权就能 `launchctl kickstart gui/501/...` 把有 FDA 授权的 AppPorts 代理立刻拉起来（实测 < 1 秒），自己完全不碰容器数据。
4. 顺带查到竞速的真正来源不是代理写得慢，而是 **launchd 把登录代理排在「投机性启动」队列里**：上一轮开机从登录完成到代理被 spawn 隔了 **17.6 秒**，代理自己启动只花约 2 秒，挂载不到 1 秒。
{% endhint %}

## 环境 <a href="#环境" id="环境"></a>

| 项目 | 值 |
|------|-----|
| 系统 | macOS 27.0 (26A428)，Darwin 27.0.0，arm64 (T8132) |
| FileVault | **已开启**（`fdesetup status` → `FileVault is On.`；Data 卷 `FileVault: Yes (Unlocked)`） |
| 外置盘 | `/Volumes/hano` — APFS 容器 `disk7`（未加密） |
| 容器卷 1 | `disk7s2` / `BEAF241C-…` → `…/Data/Documents/xwechat_files/wxid_1zxh3e4ctfeh22_9c44` |
| 容器卷 2 | `disk7s3` / `FD3DDDE6-…` → `…/Data/Library/Application Support/com.tencent.xinWeChat` |
| TCC 现有授权 | `com.shimoko.AppPorts` → `kTCCServiceSystemPolicyAllFiles`（FDA，已允许） |
| 全程 | 没有执行任何 `codesign --sign`，没有改动挂载记录 |

## 探测 1：系统域 root 守护进程能不能挂到容器路径 <a href="#探测-1-系统域-root-守护进程能不能挂到容器路径" id="探测-1-系统域-root-守护进程能不能挂到容器路径"></a>

用一个临时 LaunchDaemon（`com.appports.probe.mount`）在**系统域**跑 `/bin/sh` 脚本，目标是挂一个 64 MB 的 APFS 测试映像到
`~/Library/Containers/com.apple.TextEdit/Data/ap-probe-target`：

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

同时抓 `log stream`，拿到的是 TCC 判定原文（`<private>` 是系统脱敏，对照下一段）：

```text
2026-09-22 02:45:10.080 Df tccd … one instance of XPC forwardMessage … (service=kTCCServiceSystemPolicyAppDataDetailed, requestor=com.apple.sandboxd, target_pid=9204, target_id=com.apple.sh, auid=0)
2026-09-22 02:45:10.082 Df sandboxd[429:190b1] [com.apple.sandbox:sandcastle] checking kTCCServiceSystemPolicyAppDataDetailed on path "<private>", user interaction not allowed
2026-09-22 02:45:10.082 Df sandboxd[429:190b1] [com.apple.sandbox:sandcastle] TCC denied kTCCServiceSystemPolicyAppDataDetailed for <private>
2026-09-22 02:45:10.082 E  kernel[0:18c57] (Sandbox) System Policy: diskutil(9215) deny(1) file-mount /Users/wangheng/Library/Containers/com.apple.TextEdit/Data/ap-probe-target
2026-09-22 02:45:10.165 E  kernel[0:1943d] (Sandbox) System Policy: ls(9223) deny(1) file-read-data /Users/wangheng/Library/Containers/com.apple.TextEdit/Data/ap-probe-target
```

注意 `auid=0`（root）也一样被拒，而且 `user interaction not allowed` —— 守护进程没有会话，系统连问都不问，直接拒。

## 探测 2：同样的命令，换个上下文就成功 <a href="#探测-2-同样的命令-换个上下文就成功" id="探测-2-同样的命令-换个上下文就成功"></a>

同样的 root 身份，但由**用户会话里的终端**提权执行：

```console
$ sudo diskutil mount -mountPoint /Users/wangheng/Library/Containers/com.apple.TextEdit/Data/ap-probe-target /dev/disk5s1
Volume APProbe on /dev/disk5s1 mounted        # ← 成功
$ sudo ls -la /Users/wangheng/Library/Containers/com.apple.TextEdit/Data/ap-probe-target
total 0                                        # ← 能读
```

对照组（root 挂到不受 TCC 保护的路径）也一次成功，说明测试映像本身没问题：

```console
$ sudo diskutil mount -mountPoint /tmp/ap-probe/mp-root /dev/disk5s1
Volume APProbe on /dev/disk5s1 mounted
```

结论：**能不能挂容器路径，取决于这个进程的 TCC 身份，而不是它的 uid。** FDA 授权是记在代码签名身份上的 —— 本机 TCC 库里就有非 GUI 的守护进程式二进制持有 FDA（`/usr/sbin/smbd`、`/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper`、`siriactionsd`，`auth_value=2`），所以「守护进程 + FDA」这条路并不是被系统排除的，只是需要给守护进程要一个 FDA。

## 探测 3：FileVault 让「登录前」直接不存在 <a href="#探测-3-filevault-让「登录前」直接不存在" id="探测-3-filevault-让「登录前」直接不存在"></a>

```console
$ fdesetup status
FileVault is On.
$ diskutil apfs list | grep -A2 "disk2s5"
|   +-> Volume disk2s5 D4B13B11-… 
|   |   APFS Volume Disk (Role):   disk2s5 (Data)
|   |   FileVault:                 Yes (Unlocked)      # ← 开机时是锁着的，"Unlocked" 是登录后
```

Data 卷上才存着 `/Users/wangheng`。登录前它没解锁，`~/Library/Containers/...` 不存在，**任何进程（root 也好、守护进程也好）都无法把卷挂到一条还不存在的路径上**。所以 A 方案的时间下限就是「用户解锁那一刻」，不是「开机那一刻」。

## 探测 4：守护进程只做「喊人」是可行的 <a href="#探测-4-守护进程只做「喊人」是可行的" id="探测-4-守护进程只做「喊人」是可行的"></a>

root 守护进程发出 kickstart（自己不碰容器）：

```console
$ # 由系统域守护进程执行
$ launchctl kickstart gui/501/com.shimoko.AppPorts.container-mount
$ echo $?
0
```

AppPorts 自己的日志里立刻出现一次代理运行：

```text
[2026-09-22 02:46:12] [INFO] [session:CA65AB0F] [pid:9519] 容器卷自动挂载代理启动
[2026-09-22 02:46:12] [INFO] [session:CA65AB0F] [pid:9519] 自动挂载代理结果   mount_point: …/wxid_1zxh3e4ctfeh22_9c44   state: alreadyMounted
[2026-09-22 02:46:12] [INFO] [session:CA65AB0F] [pid:9519] 自动挂载代理结果   mount_point: …/Application Support/com.tencent.xinWeChat   state: alreadyMounted
[2026-09-22 02:46:12] [INFO] [session:CA65AB0F] [pid:9519] 容器卷自动挂载代理退出
```

一个细节：`launchctl kickstart -k`（带 `-k` 强制重启）在**短时间内重复调用会被 launchd 节流**，命令本身会阻塞十几秒到几十秒才返回；不带 `-k` 的 `kickstart` 不会。做实验时踩过这个坑，所以探测脚本后来改成非阻塞调用 + 轮询挂载结果。

## 上一轮开机的真实时序（竞速的来源） <a href="#上一轮开机的真实时序-竞速的来源" id="上一轮开机的真实时序-竞速的来源"></a>

`log show` 里 launchd 自己的记录，pid 801 就是挂载代理：

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

代价的分布很清楚：**18 秒在 launchd 排队，2 秒在 AppPorts 自身启动，4 秒在两个卷的挂载**。微信这次没出事，只因为它自己启动后读取数据比较晚（02:23:13 启动，02:23:41 才挂好，仍在可接受范围）。换一个启动快、启动时就读数据的应用就会读到空目录。

## 受控探测的结论 <a href="#受控探测的结论" id="受控探测的结论"></a>

| 形态 | 可行性 | 依据 |
|------|--------|------|
| root 守护进程**自己在登录前**挂载 | 不可行 | FileVault：登录前容器路径不存在（探测 3） |
| root 守护进程**自己**挂载（解锁后） | 需要给守护进程单独的 FDA | 探测 1 的 `deny(1) file-mount`；TCC 身份是按代码签名算的 |
| root 守护进程**kickstart 用户代理** | 可行，不需要新授权 | 探测 4；守护进程只调用 `launchctl`，挂载动作仍由有 FDA 的 AppPorts 完成 |
| 缩短现有代理的启动延迟 | 方向有两个，见下文「开机实测」 | 一部分卡在 launchd 把传统代理排到登录项之后，一部分是登录后系统整体繁忙 |

另有一条**没有采用**的形态值得记下来：让守护进程直接运行 AppPorts 自己的可执行文件（`--mount-agent`）。FDA 是记在代码签名身份上的，`com.shimoko.AppPorts` 本机已有 FDA，所以权限这一关理论上是过的；但实测 root 身份下 AppPorts 会把家目录解析成 `/var/root`（它在那里新建了 `~/Library/Application Support/AppPorts/`、读到一个空的挂载记录、什么都没做就退出），所以这条形态必须先让程序支持显式指定用户目录，属于要改代码的方案。

## 开机实测（2026-09-22 05:48:08 那次） <a href="#开机实测-2026-09-22-05-48-08-那次" id="开机实测-2026-09-22-05-48-08-那次"></a>

探针以 LaunchDaemon（root、系统域、`RunAtLoad`）常驻，开机后 1 秒轮询一次，记录「容器路径何时可见」「kickstart 是否成功」「两个卷何时挂回容器路径」。原始日志：`sudo cat /var/log/ap-boot-probe.log`。

| 时刻 | 事件 | 来源 |
|------|------|------|
| 05:48:08 | 开机 | `kern.boottime` |
| 05:48:17 | macOS 把三个外置卷挂到 `/Volumes`（登录前） | kernel apfs `mount-complete` |
| 05:48:47.96 | **探针守护进程才被启动**（开机后 40 秒） | 探测日志 |
| 05:48:48.6 | 容器路径可见（Data 卷已解锁） | 探测日志 |
| 05:48:50.1 | 探针 kickstart → `Could not find domain for user gui: 501` | `/var/log/ap-kickstart.out` |
| 05:48:50.33 | **`loginDone`（登录完成）** | loginwindow 日志 |
| 05:48:54 | 微信被登录项拉起，此时容器路径还是空目录 | `ps -o lstart` |
| 05:49:15 | **AppPorts 代理才被 launchd spawn**（pid 916，登录后 24.7 秒） | AppPorts 日志 |
| 05:49:24 → 05:49:27 | 两个卷先卸后挂完成 | AppPorts 日志（`diskutil` 逐条 TRACE） |

三条结论：

1. **「登录前」是幻想**：连 root 守护进程自己都被 launchd 排到开机后 40 秒才跑，比 macOS 挂外置卷晚 31 秒；它跑起来的那一刻 Data 卷刚解锁，容器路径刚可见。
2. **kickstart 只差了 0.2 秒**：探针 05:48:50.1 发出 kickstart，`loginDone` 是 05:48:50.33 —— 会话域刚好还没建好，于是拿到 `Could not find domain for user gui: 501`。探针当时只试了一次就进入轮询，没有重试，所以没能证明后面的收益。**如果它每秒重试，`loginDone` 后一秒内就能把代理踢起来，比实际的 05:49:15 早约 21 秒，比微信（05:48:54）读到数据也早。**
3. **代理自己也被 launchd 压后了 24.7 秒**：`loginDone` 是 05:48:50，代理 05:49:15 才被 spawn —— 微信这样的登录项 3.7 秒就起来了。原因是登录后一段时间用户域处于 on-demand-only 模式，`RunAtLoad` 这种"可以等"的任务会被延后（上一轮开机留下的原文：`pending spawn, domain in on-demand-only mode` → 17.6 秒后 `Successfully spawned … because speculative`）。
4. 代理 05:49:15 被拉起，05:49:24 才发出第一条 `diskutil` 输出（9 秒空档，日志里没有任何命令），然后到 05:49:27 挂完。同一时刻系统正忙着登录收尾（storagekitd 在探测卷、第三方监控在扫容量），代理那几次 `diskutil` 当时每次约 1 秒 —— 而现在空载测只要 0.1–0.2 秒。这一段是登录后系统整体繁忙，不是哪一条命令写错了。

顺带记录的对照：微信 05:48:54 启动、05:49:27 数据才挂回来，中间 33 秒读的是空目录，但它没有往本地写任何东西（否则挂载会因「挂载点不为空」失败），数据挂回来之后自己恢复了 —— 会话列表、聊天记录、05:49 之后的新消息都正常。真正兜底的是这一条：**挂载点始终是空的，所以数据不会分叉。**

### A 方案的判定 <a href="#a-方案的判定" id="a-方案的判定"></a>

**「让登录前挂载」这个目标不做**（FileVault 决定它不可能），但**「不等 launchd 排队、尽早把代理踢起来」这个目标价值很大：约 20 秒**，也就是现在整个竞速窗口的大头。

| 形态 | 判定 |
|------|------|
| 守护进程登录前挂载 | 不可行（FileVault） |
| 守护进程自己挂载（解锁后） | 要额外 FDA，且不比用户代理早 |
| 守护进程 kickstart 用户代理（**必须带重试**） | 机制已验证（kickstart 能让代理当秒启动），收益约 20 秒；代价是一个系统级守护进程 + 一次管理员安装 |
| 让代理自己不被排队 | ✅ **实测有效**：`KeepAlive { SuccessfulExit: false }` 去掉 `ProcessType: Background`，代理从「登录后 24.7 秒才启动」变成「登录后 4.6 秒启动」，见下面「重启实测」一节 |

另一条不装系统组件、值得试的路：把代理从「`~/Library/LaunchAgents` 传统代理」换成 `SMAppService` 登录项，让它和微信这类登录项在同一批被 launchd 拉起。代价是要把 plist 放进 `Contents/Library/LaunchAgents/`（改 Xcode 工程 + 重新签名部署），收益同样是那 20 秒，但不一定和登录项一样早 —— 没有实测过。

## 重启后自查（验证 `KeepAlive` 是否真的让代理提前） <a href="#重启后自查-验证-keepalive-是否真的让代理提前" id="重启后自查-验证-keepalive-是否真的让代理提前"></a>

机器上现在的代理定义（`~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist`）：

```xml
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>LimitLoadToSessionType</key><array><string>Aqua</string></array>
<key>WatchPaths</key><array><string>/Volumes</string></array>
```

对比改动前的定义：多了 `KeepAlive`，去掉了 `ProcessType = Background`（它等于主动告诉 launchd「我不急」，与目的相反）。`KeepAlive` 里的 `SuccessfulExit: false` 意思是「**失败才重启**」；代理的实现里无论挂载成功还是失败都以 `exit(0)` 结束（失败只写日志），所以这里不会出现重启循环 —— `KeepAlive` 的唯一作用是让 launchd 把这条任务当成「需要运行」，别在登录时把它排队。

重启后跑这个脚本，它把「开机 → 外置卷挂上 → 登录完成 → 代理被 spawn → 微信启动 → 卷挂回容器路径」按时间排出来：

```bash
bash ~/sandbox-test-backup/check-boot-timeline.sh
```

| 看到的现象 | 判定 |
|------|------|
| 代理 spawn 时刻 ≈ `loginDone`（差 1–3 秒） | `KeepAlive` **有效**：比原来的 17–25 秒提前约 20 秒，和微信同一批起来，竞速窗口基本关掉 |
| 代理 spawn 时刻 ≈ `loginDone` + 17 秒以上 | `KeepAlive` **无效**，launchd 照样把 RunAtLoad 任务排队 → 转用带重试的 kickstart 守护进程 |

顺手确认一条：`launchctl print gui/501/com.shimoko.AppPorts.container-mount` 里的 `runs` 不应该自己往上涨（涨了就说明 `KeepAlive` 被读成「一直重启」了）。

两个前置事实（已验证，不依赖重启）：

- 部署包 `~/Desktop/test/AppPorts-2026-09-21-fix/AppPorts.app` 已换成含本次改动的 Release 构建（2026-09-22 06:01），签名身份、TeamIdentifier、entitlements 与旧包逐项一致，`codesign --verify --deep --strict` 通过 —— 所以 TCC 的完全磁盘访问授权原样沿用（TCC 库里存的是按证书 CN 锚定的 requirement，不是 cdhash）。
- 新二进制以后台代理身份单独跑过一次（`launchctl kickstart`），日志原文：`容器卷自动挂载代理启动` → 两条 `state: alreadyMounted` → `容器卷自动挂载代理退出`，`last exit code = 0`。`alreadyMounted` 需要读容器路径才能得出，所以这条同时证明新包的 FDA 还在。

## 重启实测（2026-09-22 06:35:47 那次） <a href="#重启实测-2026-09-22-06-35-47-那次" id="重启实测-2026-09-22-06-35-47-那次"></a>

装上 `KeepAlive` 定义后重启一次，用 `bash ~/sandbox-test-backup/check-boot-timeline.sh` 取时序：

| 时刻 | 事件 | 来源 |
|------|------|------|
| 06:35:47 | 开机 | `kern.boottime` |
| 06:36:20.372 | **`loginDone`（登录完成）** | loginwindow |
| 06:36:21.276 / .301 / .327 | macOS 把三个外置卷挂到 `/Volumes`（登录后 1 秒） | kernel apfs `mount-complete` |
| 06:36:22.503 | launchd：`pending spawn, domain in on-demand-only mode` | launchd |
| 06:36:25 | **代理启动（pid 905）** = 登录完成 +4.6 秒 —— 微信同一秒也被登录项拉起（pid 956） | AppPorts 日志 / `ps -o lstart` |
| 06:36:33 | 第一次 `diskutil info` 才返回（这一条花了约 8 秒） | AppPorts TRACE |
| 06:36:38 | 第一个卷挂到容器路径，`state: mounted` | AppPorts 日志 |
| 06:36:39 | 第二个卷挂到容器路径，`state: mounted`；代理退出，`exit 0` | AppPorts 日志 |
| 06:36:39 之后 | `runs = 1`，KeepAlive 没有把代理反复重启；之后又出现的几次运行都是 WatchPaths 触发的空跑（见下一节） | `launchctl print` |

同一台机器、同两个卷，和改动前那一轮（05:48 那次）对比：

| | 改动前（05:48:08 开机） | 改动后（06:35:47 开机） |
|---|---|---|
| 代理被 launchd spawn | `loginDone` + 24.7 秒 | **`loginDone` + 4.6 秒** |
| 两个卷挂回容器路径 | `loginDone` + 37 秒 | **`loginDone` + 18 秒** |
| 代理被 spawn 前 launchd 的抱怨 | `pending spawn, domain in on-demand-only mode` → 17.6 秒后才 `Successfully spawned … because speculative` | 同样的提示出现，但只等了约 2.5 秒 |

**结论：`KeepAlive` 有效，净收益约 19 秒**，「代理排在登录项后面」这个问题关掉了。

剩下的窗口还在：微信 06:36:25 起来读空目录，06:36:38/39 数据才挂回来，中间约 13 秒。这 13 秒不是排队，是「刚登录的系统本身很忙」—— 第一次 `diskutil info` 花了约 8 秒（当时 load average 24），两次「卸载 + 挂载」占掉其余时间。同一台机器空载时同一条命令只要 0.1–0.2 秒。这次微信仍然没事：挂载点必须是空的才能挂上，而两个卷都挂上了，说明这 13 秒里微信没往本地写任何东西。

### 顺带发现：`WatchPaths` 会按子树匹配，空跑偏多（改动前就存在） <a href="#顺带发现-watchpaths-会按子树匹配-空跑偏多-改动前就存在" id="顺带发现-watchpaths-会按子树匹配-空跑偏多-改动前就存在"></a>

`launchctl print gui/501/com.shimoko.AppPorts.container-mount` 里的真实定义：

```
event triggers = {
	com.apple.launchd.WatchPaths => {
		stream = com.apple.fsevents.matching      ← 不是目录监听，是 FSEvents 按路径前缀匹配
		descriptor = { "WatchPaths" => [ 0 = "/Volumes" ] }
	}
}
```

`stream = com.apple.fsevents.matching` 意味着 `/Volumes` **子树里**任何文件变动都会触发代理 —— 包括外置盘 `/Volumes/hano` 上任何一次写入。实测：一段 5 分钟里代理被拉起 4 次（06:44:41、06:45:29、06:48:03、06:48:23），而同一时间用 kqueue 监听 `/Volumes` 目录本身是 **0 次变更**；另一段 4 分钟里两边都是 0。这些空跑全部是 `alreadyMounted` 直接返回，不调 `diskutil`、不动磁盘。空跑本身留着不管 —— 「插盘后自动重挂」正靠它 —— 但日志做了压缩：**一轮空跑只写 3 行**

```
容器卷自动挂载代理启动
容器卷自动挂载代理结束：2 个挂载点都已在位，无操作     ← TRACE
容器卷自动挂载代理退出
```

逐条详单只在真的动过卷（`mounted`）、卷读不到（`unavailable`）或挂载失败（`failed`）时才写。改之前一轮空跑 9 行，按上面的实测频率一天能刷掉近 1 MB。

这一条不是这次改动引入的（改动前 02:4x 也有过 20 分钟 23 次的记录）。

## 后续加固：把「再试一次」挂到 `/Volumes` 的真实事件上（2026-09-23） <a href="#后续加固-把「再试一次」挂到-volumes-的真实事件上-2026-09-23" id="后续加固-把「再试一次」挂到-volumes-的真实事件上-2026-09-23"></a>

### 起因 <a href="#起因" id="起因"></a>

2026-09-21 11:10 与 09-23 06:00 两次开机，代理日志都是 `state: failed("挂载后校验失败，该路径不是挂载点：…")`，用户随后看到「原先挂载的显示 0 字节」「微信不好使」。

### 根因：`diskutil mount -mountPoint` 会「假装成功」 <a href="#根因-diskutil-mount-mountpoint-会「假装成功」" id="根因-diskutil-mount-mountpoint-会「假装成功」"></a>

`diskutil mount -mountPoint <路径> <卷>` 在**卷已经挂载**时不会报错，而是忽略挂载点参数、直接打印 `mounted` 并返回 0。开机/插盘时 macOS 自己会先把卷自动挂到 `/Volumes/AppPorts-…`，代理读 `diskutil info` 的那一刻自动挂载可能还没完成（`MountPoint` 是空的），于是「不用先卸载」这条判断成立，接着这条命令就成了空操作 —— 命令成功、挂载点是空的，校验（`statfs` 判定）如实发现并报失败，然后放弃。

用临时 APFS 映像复现（卷已挂在 `/Volumes/APProbeVol`，再指定别的挂载点）：

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

顺带确认了一件事：校验逻辑本身没问题，判的是实话 —— 它发现了卷不在目标路径上。缺的是**发现之后要接着重试**，而不是收工。

### `/Volumes` 的事件能在 0.1 秒内等到 <a href="#volumes-的事件能在-0-1-秒内等到" id="volumes-的事件能在-0-1-秒内等到"></a>

用临时 APFS 映像测 kqueue 监听 `/Volumes`（`NOTE_WRITE|DELETE|EXTEND|RENAME|LINK|ATTRIB`）：

```
1.12s -> attach 开始
1.24s 收到事件 fflags=0x12     ← 比 hdiutil 自己返回（1.27s）还早
1.26s 收到事件 fflags=0x2
1.27s -> attach 退出码 0
```

挂载与卸载都改动 `/Volumes` 目录本身，事件在 120ms 内到达；`fflags=0x2`（NOTE_DELETE）属于同一个抖动的第二次通知（实测 6 卷一起插拔时也会成串出现）。所以「等卷出现」可以做成**目录事件等待**，而不是定时器：事件之后留 1 秒安静窗口再动手（事件比卷可用早约 100ms），抖动算一次变化。

### 改动 <a href="#改动" id="改动"></a>

| 位置 | 改动 |
|------|------|
| `DiskUtility.isMountPoint` | 路径比较补上 `realpath()`。`URL.resolvingSymlinksInPath()` 在 macOS 27 上**不解析 `/tmp`**（返回 `/tmp/...`），而 `statfs` 给的是 `/private/tmp/...`，只比这两种写法会把明明挂上的卷判成「不是挂载点」 |
| `ContainerVolumeMigrator.mountVolume` | 挂载后校验；没落到位就重新查一次卷挂在哪、把它从别处卸下来再挂，最多 3 轮（每轮间隔 0.5 秒）。校验以 `statfs` 为主判据，`diskutil` 的挂载点为权威兜底 |
| `VolumeChangeMonitor`（新） | kqueue 监听目录变化的等待器，带安静窗口与 inode 变化后的重新打开 |
| `ContainerRemountLoop`（新） | 重试策略：只在事件到达时重试，事件缺席时 20 秒兜底复查，总窗口 180 秒，最多 20 轮 |
| `ContainerMountAgentInstaller` | 代理改成「拿锁 → 试一轮 → 放锁 → 等事件 → 再试」，**等卷期间不占锁**；第一轮照旧等满 120 秒，之后每轮只等 10 秒 |
| `ContainerVolumeMigrator.knownMountPoint` | 挂载前先试零成本的快路径：`statfs` 看 `/Volumes/<卷名>` 是不是挂载点 + 读卷根标记确认是自己的卷（微秒级），认不出来才退回 `diskutil info` |

### 真机验证（2026-09-23 08:04，微信卷未受影响） <a href="#真机验证-2026-09-23-08-04-微信卷未受影响" id="真机验证-2026-09-23-08-04-微信卷未受影响"></a>

造了一个临时 APFS 卷 + 一条临时挂载记录（原 `container-mounts.plist` 已备份），把卷弹掉之后 kickstart 代理：

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

同一次运行里两个微信卷报 `alreadyMounted`，没有被这一轮影响。收工后再跑一次代理：`容器卷自动挂载代理结束：2 个挂载点都已在位，无操作`，回到常态。

另一组对照：把卷预先挂到 `/Volumes` 再让代理跑（0.6/0.8/1.0/1.2/1.4/1.6/1.8 秒七个延迟各试一次），七次全部正确收尾到目标路径（其中 6 次走「先卸载再挂」）。**「校验失败 → 重试」那一支没有在真机上复现出来**：它的触发窗口是「读 `MountPoint` 与卷真正挂上之间」的几十毫秒，而代理从启动到读 `info` 要一秒上下，很难主动撞上（历史上是自然发生的两次）。这一支由假 runner 的单测覆盖（`reclaimsVolumeFromForeignAutomount`、`failsAfterMountAttempts`）。

### 第二轮加固（2026-09-23 14:4x）：省掉开机时那次 9 秒的 `diskutil` 查询 <a href="#第二轮加固-2026-09-23-14-4x-省掉开机时那次-9-秒的-diskutil-查询" id="第二轮加固-2026-09-23-14-4x-省掉开机时那次-9-秒的-diskutil-查询"></a>

2026-09-23 13:56 那次开机（改动后第一次重启）时序如下 —— 空窗仍在约 15 秒，但成因已经不含"代理被排队"：

| 时刻 | 事件 |
|------|------|
| 13:55:52（开机 +7s） | 三个卷被系统自动挂到 `/Volumes` |
| 13:56:17.4 | 登录完成 |
| 13:56:21.4 | 微信被拉起，读到空目录 |
| 13:56:22（登录完成 +4.6s） | 代理启动（`KeepAlive` 依旧有效） |
| 13:56:23 → 13:56:32 | **第一次 `diskutil info` 花了 9 秒**（登录后系统正忙） |
| 13:56:35 → 13:56:37 | 卸掉系统挂在 `/Volumes` 的卷、再挂到容器路径 |

拆开看：4.6 秒（代理启动）+ 9 秒（`diskutil info`）+ 约 4 秒（卸载系统挂载点）+ 不到 1 秒（挂载）。

那 9 秒的查询原本的作用是"一次问清卷在不在线 + 现在挂在哪"。但开机场景下卷一定是被系统挂到 `/Volumes/<卷名>`，而卷名就存在记录里 —— 用 `statfs` 看一眼这个路径、再读一次卷根标记（`.appports-mount-metadata.plist` 里的 `volumeUUID`）就能确认是自己的卷，两次本地调用都是微秒级。认不出来（卷名被系统改名、标记缺失、卷压根没挂上）就退回 `diskutil` 查询，行为不变。安全性上，标记里的 UUID 必须与记录一致才会去卸载那个挂载点，避免误卸同名的别的卷。

真机验证（临时 APFS 卷 + 临时记录，微信卷不受影响）：

```
[14:42:59] 容器卷自动挂载代理启动
[14:42:59] 卷已由系统挂在自动挂载点，直接切换   current_mount_point: /Volumes/AppPorts-e2e-fast
[14:42:59] 容器卷已挂在其它位置，先卸载再挂到容器路径
[14:42:59] diskutil unmount /Volumes/AppPorts-e2e-fast      → status 0
[14:43:00] diskutil mount -mountPoint /tmp/ap-fast/mountpoint DA3C9BD2-…  → status 0
[14:43:00] 容器卷已挂载
[14:43:00] 容器卷自动挂载代理退出
```

整轮**没有任何 `diskutil info`**，只剩 `unmount` + `mount` 两条命令，约 1 秒结束；同一次运行里两个微信卷报 `alreadyMounted`。三个新用例守着这条路径（命中快路径、标记不匹配时退回查询、卷没挂上时退回查询）。

## 附：探测脚本（实测后已撤除） <a href="#附-探测脚本-实测后已撤除" id="附-探测脚本-实测后已撤除"></a>

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

## 相关文档 <a href="#相关文档" id="相关文档"></a>

- [挂载迁移](../datamigrae/mount-migration.md)
- [实验记录：沙盒应用 + 挂载点](sandbox-mountpoint.md)
- [实验记录：沙盒应用 + 符号链接](sandbox-symlink.md)
