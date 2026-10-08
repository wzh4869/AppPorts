# 实验记录：沙盒应用 + 符号链接（macOS 27）

本文是一次**受控实验**的原始记录，面向想核对证据的读者；面向用户的结论见[容器数据、沙盒与签名身份](../datamigrae/container-identity.md)。实验回答的问题是：

> 容器数据被复制到外部卷、原位置留下符号链接之后，**在不重签名**的前提下，沙盒应用能不能读到这些数据？

结论是**不能**。而且这与外部卷无关——只要目标在容器之外，沙盒就会拒绝。

{% hint style="success" %}
**一句话结论**

沙盒应用读写容器数据时，内核按**符号链接解析后的真实路径**做沙盒判定。

- 指向 `/Volumes/...`（外部卷）→ 拒绝
- 指向 `~/Desktop/...`（内置卷、容器外）→ 同样拒绝
- 指向容器内部 → 正常放行

因此对沙盒应用来说，「只迁移、不重签名」**不是一个安全选项**，而是「应用能启动、但读不到数据」。
{% endhint %}

## 环境 <a href="#环境" id="环境"></a>

| 项目 | 值 |
|------|-----|
| 系统 | macOS 27.0 (26A428)，Darwin 27.0.0，arm64 (T8132) |
| SIP | enabled |
| 外部卷 | `/Volumes/hano` — `apfs, local, nodev, nosuid, journaled, noowners` |
| 测试应用 A | 便签 Stickies — `/System/Applications/Stickies.app`，`com.apple.Stickies` |
| 测试应用 B | 微信 WeChat 4.1.15 (270099) — 开发者签名，非重签名 |
| 方法 | 符号链接重定向 + `open -a` 启动 + `log stream` 抓沙盒判定 |

### 测试应用的 entitlements <a href="#测试应用的-entitlements" id="测试应用的-entitlements"></a>

便签（`com.apple.Stickies`）——确认是真正的沙盒应用：

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.print</key><true/>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array><string>/Library/Preferences/widget-com.apple.widget.stickies.plist</string></array>
```

微信 4.1.15（官方 Developer ID 签名，`Tencent Mobile International Limited (5A4RE8SF68)`）——同样是沙盒应用，**未被重签名**：

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

两个应用都**没有**任何覆盖任意路径的临时例外：

- `files.user-selected.*` 只对用户在 Open/Save 面板里亲自选中的文件生效，不覆盖固定路径；
- `files.downloads.read-write` 只覆盖 `~/Downloads`；
- `temporary-exception.sbpl` 只开放了一个 **network-outbound** 字面量，不涉及文件系统。

## 结果 <a href="#结果" id="结果"></a>

### 便签（符号链接重定向 `Data/Library/Stickies`） <a href="#便签-符号链接重定向-data-library-stickies" id="便签-符号链接重定向-data-library-stickies"></a>

| 场景 | 符号链接目标 | 应用能否启动 | 能否读到数据 | 沙盒 deny 日志 | 应用是否重建空目录 |
|------|--------------|:---:|:---:|:---:|:---:|
| 主实验 | `/Volumes/hano/sandbox-test/...`（外部卷） | 能 | **否** | 有 | 否 |
| C1 | `~/Desktop/sandbox-test/...`（内置卷、容器外） | 能 | **否** | 有 | 否 |
| C2 | 容器内 `Data/tmp/relocated/...` | 能 | 能 | 无 | — |
| C3 | 无符号链接（原目录） | 能 | 能 | 无 | — |

可观测指标用的是便签的**窗口数量与标题**：原目录里有 2 张便签，能读到时会恢复成 2 个窗口并带真实标题，读不到时只剩 1 个空白「未命名」窗口。

```
场景                        窗口数  窗口标题
主实验（/Volumes）            1     未命名              ← 读不到
C1（~/Desktop）               0     —                   ← 读不到
C2（容器内）                  2     制作便条！… / 自定便条很简单。…
C3（阳性对照）                2     制作便条！… / 自定便条很简单。…
```

三次「符号链接被拒」的场景里，符号链接本身都**完好保留**，应用也没有在本地重建同名目录——它只是读不到、然后按「没有任何便签」继续跑。

### 微信（符号链接重定向 `Data/Documents/xwechat_files/wxid_...`） <a href="#微信-符号链接重定向-data-documents-xwechat-files-wxid" id="微信-符号链接重定向-data-documents-xwechat-files-wxid"></a>

| 场景 | 应用签名 | 数据位置 | 应用能否启动 | 能否读到数据 | 日志 |
|------|----------|----------|:---:|:---:|------|
| W1 | Ad-hoc 重签名 | 外部卷（符号链接） | 否（约 0.9 s 退出） | 否 | TCC App Data 拒绝 |
| W2 | 官方签名 | 外部卷（符号链接） | 能 | **否** | 沙盒 `file-read-data` 拒绝 + UI 报错 |
| W3 | 官方签名 | 本地（阳性对照） | 能 | 能 | 无拒绝 |
| W4 | Ad-hoc 重签名 | 本地 | 否（秒退） | 否 | TCC App Data 拒绝 |

## 决定性日志原文 <a href="#决定性日志原文" id="决定性日志原文"></a>

### 便签 · 主实验（外置卷） <a href="#便签-·-主实验-外置卷" id="便签-·-主实验-外置卷"></a>

```
2026-09-18 06:19:41.380 E  kernel[0:5f489] (Sandbox) Sandbox: Stickies(41548) deny(1) file-read-data /Volumes/hano/sandbox-test/com.apple.Stickies/Library-Stickies/.SavedStickiesState
2026-09-18 06:19:41.468 E  kernel[0:5f489] (Sandbox) Sandbox: Stickies(41548) deny(1) file-read-data /Volumes/hano/sandbox-test/com.apple.Stickies/Library-Stickies
2026-09-18 06:19:43.485 E  kernel[0:5f489] (Sandbox) Sandbox: Stickies(41548) deny(1) file-write-unlink /Volumes/hano/sandbox-test/com.apple.Stickies/Library-Stickies/.SavedStickiesState
```

### 便签 · C1（主目录内的容器外路径） <a href="#便签-·-c1-主目录内的容器外路径" id="便签-·-c1-主目录内的容器外路径"></a>

```
2026-09-18 06:20:08.519 E  kernel[0:6024f] (Sandbox) Sandbox: Stickies(42084) deny(1) file-read-data /Users/<user>/Desktop/sandbox-test/com.apple.Stickies-Library-Stickies/.SavedStickiesState
2026-09-18 06:20:08.599 E  kernel[0:6024f] (Sandbox) Sandbox: Stickies(42084) deny(1) file-read-data /Users/<user>/Desktop/sandbox-test/com.apple.Stickies-Library-Stickies
2026-09-18 06:20:08.599 E  kernel[0:6024f] (Sandbox) Sandbox: Stickies(42084) deny(1) file-write-create /Users/<user>/Desktop/sandbox-test/com.apple.Stickies-Library-Stickies/DB5CDB21-9A90-438C-ACCB-614F1F0018DE.rtfd
```

C1 与主实验的拒绝形式**完全一致**，说明关键在于「路径在容器之外」，而不是「路径在 `/Volumes`」。

### 微信 · W2（官方签名 + 外置卷） <a href="#微信-·-w2-官方签名-外置卷" id="微信-·-w2-官方签名-外置卷"></a>

界面明确报错：

> ⚠️ 存储权限异常
> 存储位置不能使用，WeChat 将无法使用，请检查此文件夹是否可用。

对应的沙盒日志：

```
2026-09-18 06:25:26.194 E  kernel[0:5f65e] (Sandbox) WeChat(43498) deny(1) file-read-data /Volumes/hano/appdisks/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1zxh3e4ctfeh22_9c44/db_storage/contact/contact.db
```

微信在**未重签名**的情况下被沙盒拒绝读取自己的通讯录数据库。此时它已经成功启动、显示出账号头像与昵称（这些来自容器内 `all_users/` 的本地文件），但一旦真正去读账号数据目录就失败。

### 微信 · W3（官方签名 + 本地数据，阳性对照） <a href="#微信-·-w3-官方签名-本地数据-阳性对照" id="微信-·-w3-官方签名-本地数据-阳性对照"></a>

同一份数据放回容器本地后，微信正常打开全部数据库：

```
WeChat 46541 wangheng  101r  REG  1,14  8450048  99926627 /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1zxh3e4ctfeh22_9c44/db_storage/contact/contact.db
WeChat 46541 wangheng   99u  REG  1,14  4194304  99926632 /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_1zxh3e4ctfeh22_9c44/db_storage/contact/contact.db-wal
```

聊天列表完整显示，历史记录可读，无任何 `deny`。

### 微信 · W1 / W4（Ad-hoc 重签名） <a href="#微信-·-w1-w4-ad-hoc-重签名" id="微信-·-w1-w4-ad-hoc-重签名"></a>

```
Failed to match existing code requirement for subject com.tencent.xinWeChat and service kTCCServiceSystemPolicyAppDataDetailed
sandboxd rejected approval request from WeChat for kTCCServiceSystemPolicyAppData (/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/net/config.ini): denied
```

W4 中数据**完全在本地**，日志里也没有任何 `/Volumes` 相关的拒绝——说明重签名导致的失败与数据位置无关，是独立的一条故障链。

## 结论 <a href="#结论" id="结论"></a>

| | 数据在本地 | 数据在外置卷（符号链接） |
|---|---|---|
| **官方签名（沙盒）** | ✅ 正常，聊天记录完整 | ❌ 启动正常，读取被拒（「存储权限异常」） |
| **Ad-hoc 重签名（非沙盒）** | ❌ TCC App Data 拒绝，秒退 | ❌ TCC App Data 拒绝，秒退 |

三条独立结论：

1. **沙盒应用无法跟随符号链接读到容器外的数据。** 内核按解析后的真实路径判定，`/Volumes` 和 `~/Desktop` 结果相同。符号链接本身不是问题——目标落在容器内时一切正常（C2）。
2. **重签名会独立地破坏容器归属。** 即使数据完全在本地，Ad-hoc 重签名后的应用也会被 `kTCCServiceSystemPolicyAppData` 拒绝访问自己的容器（W4）。
3. **「只迁移，不重签名」对沙盒应用不可行。** 它不会让应用崩溃，但会让应用静默读不到数据并给出「存储位置不可用」之类的错误——比直接启动失败更难排查。

### 对 AppPorts 的含义 <a href="#对-appports-的含义" id="对-appports-的含义"></a>

对 `~/Library/Containers/` 与 `~/Library/Group Containers/` 下的目录：

- **「禁止重签名」不足以解决问题**——不重签名仍然读不到数据；
- 符号链接迁移对沙盒应用**在机制上不成立**，与 macOS 版本无关（macOS 26 上能「用」，靠的是重签名把沙盒拆掉，而不是符号链接生效）。

基于本实验，AppPorts 1.9.0 起对容器目录只提供[挂载迁移](../datamigrae/mount-migration.md)；后续的[挂载点实验](sandbox-mountpoint.md)验证了该方案。

### 本次实验的边界 <a href="#本次实验的边界" id="本次实验的边界"></a>

- 便签是 `/System/Applications` 下的系统应用，位于只读系统卷，AppPorts 本来也不会去迁移它。用它只是为了验证**沙盒机制本身**，结论与具体应用无关。
- 微信测试用的是从官方渠道重新安装的 `WeChat.app`（Developer ID，未重签名），与 App Store / 官网版本行为一致。
- 未测试 `~/Library/Group Containers/`，但其路径判定机制与 `Containers` 相同（同样在容器白名单之外）。
