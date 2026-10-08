# 实验记录：沙盒应用 + 挂载点（macOS 27）

本文是继[符号链接实验](sandbox-symlink.md)之后的第二轮**受控实验**的原始记录，面向想核对证据的读者；面向用户的说明见[挂载迁移](../datamigrae/mount-migration.md)。实验回答的问题是：

> 不重签名，把外置卷上的 APFS 卷**直接挂载到容器内的原路径**（真实路径留在容器内），沙盒应用能不能读写这些数据？

结论是**分应用而异**，而且取决于一个和沙盒路径规则无关的东西：TCC 的**「可移动宗卷」授权**。

{% hint style="success" %}
**一句话结论**


- 挂载点**确实绕过了沙盒的路径检查**——沙盒只比对路径字符串，容器路径上的挂载点匹配成功，内核不再判定为「容器外」。
- 但数据落在**外置卷**上会额外触发 `kTCCServiceSystemPolicyRemovableVolumes`（可移动宗卷）检查：
  - **第三方应用**（微信、Maccy、小米互联服务）→ 系统弹出「访问可移动宗卷」授权框，允许后**读写完全正常**；
  - **平台应用**（便签 Stickies）→ **不弹框、直接静默拒绝**，应用照常启动但读不到任何数据，并可能重建一个空存储。
- 「挂载到容器路径」这个动作本身还需要**Full Disk Access**：普通后台进程（例如脚本型 LaunchAgent）会被 `kTCCServiceSystemPolicyAppDataDetailed` 拒绝。
{% endhint %}

## 环境 <a href="#环境" id="环境"></a>

| 项目 | 值 |
|------|-----|
| 系统 | macOS 27.0 (26A428)，Darwin 27.0.0，arm64 (T8132) |
| 外置卷 | `/Volumes/hano` — `apfs, local, nodev, nosuid, journaled, noowners`（APFS，容器 `disk7`） |
| 测试卷 | `diskutil apfs addVolume disk7 APFS ...` 新建的临时卷（无需 root） |
| 测试应用 A | 便签 Stickies — `/System/Applications/Stickies.app`（平台应用） |
| 测试应用 B | 微信 WeChat 4.1.15 — 官方 Developer ID 签名，**未重签名** |
| 测试应用 C | Maccy — 第三方沙盒应用（Developer ID） |
| 测试应用 D | 小米互联服务 — **App Store（MAS）沙盒应用** |
| 方法 | 挂载点重定向 + `open -a` 启动 + `log stream` 抓 TCC / 沙盒判定 |
| 全程 | **没有执行任何 `codesign --sign`** |

## 实验方法 <a href="#实验方法" id="实验方法"></a>

```
SUB=~/Library/Containers/<BundleID>/Data/<子目录>     # 应用启动时会读写的子目录
EXT=/Volumes/<测试卷>

rsync -a "$SUB"/ ~/sandbox-test-backup/.../            # 备份
rsync -a "$SUB"/ "$EXT"/                               # 数据进卷
diskutil unmount "$EXT"
mv "$SUB" "$SUB.local-original"; mkdir "$SUB"          # 原目录让位
diskutil mount -mountPoint "$SUB" <测试卷>             # 卷挂到容器路径上
```

挂载后 `mount` 的显示就是容器路径本身：

```
/dev/disk7s5 on /Users/<user>/Library/Containers/com.apple.Stickies/Data/Library/Stickies (apfs, local, nodev, nosuid, journaled, noowners)
```

## 结果总表 <a href="#结果总表" id="结果总表"></a>

| 场景 | 挂载需要 sudo | 应用能启动 | 能读到卷上数据 | 能写入卷 | 沙盒 / TCC 日志 | 备注 |
|------|--------------|------------|----------------|----------|------------------|------|
| 便签 + 挂载点 | 否 | ✅ | ❌ | ❌ | `System Policy: Stickies deny(1) file-read-data ...` | 只剩 1 张空白「未命名」便签 |
| 便签 + 挂载点（第二次、换卷复测） | 否 | ✅ | ❌ | ❌ | 同上 | 可稳定复现 |
| 微信 + 挂载点 | 否 | ✅ | ✅ | ✅ | 先 `rejected ... would require prompt`，随后 `granted by TCC` | 聊天记录完整、收发正常 |
| Maccy + 挂载点 | 否 | ✅ | ✅ | ✅ | 一次 preflight 拒绝，实际访问未被拦 | SQLite 正常读写 |
| 小米互联服务（MAS）+ 挂载点 | 否 | ✅ | ✅ | ✅ | `AUTHREQ_PROMPTING` → `TCCDEvent: type=Create` | 用户授权后立即正常 |
| 盘不在（空目录） | — | ✅ | — | ✅ 写进本地 | 无 deny | 应用把数据写到了本地空目录 |
| 盘不在（`chmod 000` + `uchg`） | — | ✅ | — | ❌ | 无 deny | 静默显示空白，不报错 |
| 挂载由脚本型 LaunchAgent 发起 | — | — | — | — | `TCC denied kTCCServiceSystemPolicyAppDataDetailed` + `file-mount` 拒绝 | 挂载失败 |
| fstab（`UUID=`）| 需要 | — | — | — | `mount_apfs: volume could not be mounted` | 解析 UUID 失败 |
| fstab（`/dev/diskNsM`）| 需要 | — | — | — | — | 能挂载，但设备号不稳定 |

## 原始日志 <a href="#原始日志" id="原始日志"></a>

### 1. 便签：静默拒绝 <a href="#_1-便签-静默拒绝" id="_1-便签-静默拒绝"></a>

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

注意两点：

1. 报的是**容器内路径**（不是 `/Volumes/...`），说明沙盒路径判定已经通过；
2. 判定来源是 `System Policy:` 而不是 `Sandbox:`，即 TCC 层，服务名是 `kTCCServiceSystemPolicyRemovableVolumes`。

请求全部是 `preflight=yes`（探测式询问，不允许弹框），系统直接拒绝。应用表现：只有 `1, 未命名` 一个空窗口，原有的两张便签（卷上 `.SavedStickiesState` 2988 字节 + 两个 `.rtfd`）全部不可见。

### 2. 微信：先拒绝、后授权、之后完全正常 <a href="#_2-微信-先拒绝、后授权、之后完全正常" id="_2-微信-先拒绝、后授权、之后完全正常"></a>

```
2026-09-18 06:51:57.504 sandboxd checking kTCCServiceSystemPolicyRemovableVolumes for WeChat
2026-09-18 06:51:57.518 kernel (Sandbox) sandboxd rejected approval request from WeChat for
        kTCCServiceSystemPolicyRemovableVolumes (.../com.tencent.xinWeChat/Data/Documents/xwechat_files):
        would require prompt
2026-09-18 06:52:03.570 sandboxd kTCCServiceSystemPolicyRemovableVolumes granted by TCC for WeChat
2026-09-18 06:52:04.409 sandboxd kTCCServiceSystemPolicyRemovableVolumes granted by TCC for WeChat
```

授权之后：

- 微信完整启动、登录态保留、聊天列表与历史记录完整；
- `lsof` 显示 173 个句柄落在 `xwechat_files/wxid_...`、15 个落在 `all_users`，设备号指向外置卷；
- 卷上的 `contact.db` / `contact.db-wal` / `contact_fts.db` 时间戳随使用持续更新（读写在卷上真实发生）；
- **没有任何针对 `xwechat_files` 的文件级 `deny`**。

### 3. 小米互联服务（App Store 应用）：明确的授权弹框 <a href="#_3-小米互联服务-app-store-应用-明确的授权弹框" id="_3-小米互联服务-app-store-应用-明确的授权弹框"></a>

```
2026-09-18 07:00:49.976 tccd AUTHREQ_CTX: service=kTCCServiceSystemPolicyRemovableVolumes, preflight=no
2026-09-18 07:00:50.001 tccd AUTHREQ_PROMPTING: service=kTCCServiceSystemPolicyRemovableVolumes,
        subject=Sub:{com.xiaomi.hyperConnect}
2026-09-18 07:00:53.814 tccd Publishing <TCCDEvent: type=Create,
        service=kTCCServiceSystemPolicyRemovableVolumes, identifier=com.xiaomi.hyperConnect>
```

授权后应用把新的日志文件直接写进了卷上：

```
小米互联服务_dist_camera_202609180700_055532_000.log
  dev=16777253（外置卷）   内置数据卷 dev=16777230
```

### 4. 把卷挂到容器路径，需要 Full Disk Access <a href="#_4-把卷挂到容器路径-需要-full-disk-access" id="_4-把卷挂到容器路径-需要-full-disk-access"></a>

同一个命令，只换调用者，结果相反：

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

对应的 TCC 授权记录：

```
kTCCServiceSystemPolicyAllFiles | com.openai.codex   | auth_value=2   ← 已授权
kTCCServiceSystemPolicyAllFiles | com.apple.Terminal | auth_value=0   ← 未授权
```

### 5. fstab 持久化 <a href="#_5-fstab-持久化" id="_5-fstab-持久化"></a>

```
# 用 UUID=
$ sudo mount -a
mount_apfs: volume could not be mounted: Permission denied
mount: /Users/<user>/Library/Containers/.../xwechat_files failed with 66

# 改成设备节点
/dev/disk7s2 /Users/<user>/Library/Containers/.../xwechat_files apfs rw,nobrowse 0 0
$ sudo mount -a      → 挂载成功
```

## 结论 <a href="#结论" id="结论"></a>

### (1) 挂载点方案对沙盒应用是否可行 <a href="#_1-挂载点方案对沙盒应用是否可行" id="_1-挂载点方案对沙盒应用是否可行"></a>

**可行，但有前提。** 与符号链接不同，挂载点的路径字符串落在容器内，沙盒的容器规则本身就写了允许：

```
;; /System/Library/Sandbox/Profiles/appsandbox-common.sb
(define (appsandbox-container-macos)
  (allow file-ioctl file-mknod file-revoke file-search file-mount file-unmount
         (container-subpath "")))
```

而 `container-subpath` / `container-regex` 用的是 `resolving-*` 系列匹配（先解析符号链接再比对路径字符串），挂载点在解析后仍是容器路径，因此匹配成功。

**但真正的闸门是 TCC**：数据在外置卷上，会触发 `kTCCServiceSystemPolicyRemovableVolumes`。第三方应用能弹框并获得授权，平台应用只会拿到 preflight 拒绝。

### (2) 失败时的具体机制 <a href="#_2-失败时的具体机制" id="_2-失败时的具体机制"></a>

便签这一类应用失败的链路是：

```
应用读容器内的文件
  → 路径判定通过（挂载点在容器内）
  → 内核发现 vnode 在外置卷 → 要求 kTCCServiceSystemPolicyRemovableVolumes
  → sandboxd 以 preflight 询问，不能弹框
  → 返回 "would require prompt" 并拒绝
  → System Policy: deny(1) file-read-data
```

应用看到的是普通的「读不到文件」，既没有弹框也没有报错，于是按「首次运行」处理：显示空白、并试图在容器里新建存储（同样被拒）。

### (3) 盘不在时的安全对策 <a href="#_3-盘不在时的安全对策" id="_3-盘不在时的安全对策"></a>

| 做法 | 应用能启动 | 结果 |
|------|------------|------|
| 空目录 | ✅ | 应用把数据写进**本地空目录**，与卷上数据分叉 |
| `chmod 000` + `chflags uchg` | ✅ | 应用静默显示空白，不写入、不报错 |

两种做法都**不会报错**，也**不会阻止应用启动**，所以存在「用户以为在用旧数据、实际在用一份新数据」的风险。AppPorts 采用第二种，并在挂载点里出现本地文件时拒绝再挂载，避免盖住这份数据。

### (4) 与理论不符的现象 <a href="#_4-与理论不符的现象" id="_4-与理论不符的现象"></a>

1. **平台应用与第三方应用行为不同。** 同为沙盒应用，便签拿到的只有 preflight 拒绝且不弹框，而微信 / Maccy / 小米都能走到授权弹框。这一差异在日志里可复现，但**为什么平台应用不发起可弹框的请求，本次没有查到确凿依据**。
2. **微信第一次被拒后约 6 秒自动变成「granted by TCC」。** 日志里没有抓到对应的 `AUTHREQ_PROMPTING` 行（小米那次抓到了）。这次授权是否确实出现过授权框并由用户点了允许，日志无法证明；结论 1 的表述以「平台应用只发起不可弹框的 preflight 请求」为准。
3. **Maccy 只有一次 preflight 拒绝，之后没有任何 deny，读写却正常。** 说明被拒的那次探测并不代表后续访问真的被拦。
4. **本文只覆盖 macOS 27。** 旧系统的补充验证见下文。

## 对 AppPorts 的含义 <a href="#对-appports-的含义" id="对-appports-的含义"></a>

- **挂载点 + 不重签名** 对第三方沙盒应用**是可行的**，微信这种真实案例已跑通；这是符号链接方案做不到的。
- 平台应用（`/System/Applications` 下的系统应用）会静默失败；AppPorts 本来就不迁移它们。
- **执行挂载的进程必须有 Full Disk Access**：普通脚本型 LaunchAgent 做不到，因此后台重挂由 AppPorts 自身的可执行文件以 `--mount-agent` 参数运行，复用主应用的授权。
- **不用 `/etc/fstab` 做持久化**：`UUID=` 形式解析失败；`/dev/diskNsM` 形式设备号会随插拔顺序变化，且开机阶段由 root 挂载，同样受 TCC 限制。
- 应用首次访问外置卷时会出现**系统授权框**，这是用户可见的一次性步骤。

## 后续补充 <a href="#后续补充" id="后续补充"></a>

- **macOS 12（2026-09-19）**：同一套流程在 macOS 12 上执行时，`diskutil mount -mountPoint` 被 DiskArbitration 拒绝（`kDAReturnNotPrivileged`，普通用户不能把卷挂到自定义路径）。以管理员权限重试后成功，应用能正常读到卷上的数据，说明 12 的沙盒 profile 同样放行容器内挂载点。AppPorts 因此在遇到该错误时弹出系统密码框重试；登录代理没有界面，在这类系统上不能自动重挂。macOS 13 到 26 之间哪一版开始放开尚未逐一验证。
- **拔盘数据安全（2026-09-19）**：见[实验记录：拔盘对 APFS 卷与磁盘映像的影响](unplug-test.md)。

## 实验边界 <a href="#实验边界" id="实验边界"></a>

- 全程**没有重签名**，所有测试应用都保持原始签名。
- 便签位于只读系统卷，AppPorts 不会迁移它；用它只是为了验证沙盒机制本身。
- **没有真实重启机器**。fstab 的开机行为是用 `sudo mount -a` 模拟的，结论以模拟结果为准。
- `~/Library/Group Containers/` 未单独测试，但其路径判定机制与 `Containers` 相同。
- 测试用的临时 APFS 卷、fstab 行、LaunchAgent、被移动的目录均已还原。
