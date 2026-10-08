# 容器数据、沙盒与签名身份

{% hint style="success" %}
**一句话结论**

`~/Library/Containers/` 和 `~/Library/Group Containers/` 里的数据属于**沙盒应用**。这类数据用"快捷方式"（符号链接）搬到外置盘是读不到的；AppPorts 以前靠「重签名」绕过这一点，代价是应用在 macOS 27 上可能无法打开，登录态也可能丢失。

从 1.9.0 起，容器数据改用[挂载迁移](mount-migration.md)，签名一个字节都不动。已经被重签名过的应用需要重装，步骤见 [macOS 27 升级说明](../macos-27.md)。
{% endhint %}

这篇文档解释来龙去脉。如果你的应用已经打不开了，直接去 [macOS 27 升级说明](../macos-27.md) 看修复步骤。

## 容器是什么 <a href="#容器是什么" id="容器是什么"></a>

macOS 上大部分应用运行在"沙盒"里：系统给每个应用分配一个专属文件夹，就是 `~/Library/Containers/<Bundle ID>/`，应用只能在里面读写。App Store 上架的应用必须这样，微信、QQ 音乐这类官网下载的应用也大多这样。多个应用共享的数据放在 `~/Library/Group Containers/`。

判断一个应用是不是沙盒应用，看它的授权信息里有没有 `com.apple.security.app-sandbox`：

```bash
codesign -d --entitlements - --xml /Applications/WeChat.app 2>/dev/null | grep -c app-sandbox
# 输出 1 就是沙盒应用
```

有一点容易被忽略：**主程序不沙盒，不代表它的容器可以随便动。** Chrome、Edge 的主程序不在沙盒里，但它们的小组件和扩展各有自己的容器；那些容器的主人是沙盒进程。所以 AppPorts 对 `Containers` 下的所有目录一视同仁，不看主程序。

## 搬走容器数据的三条路 <a href="#搬走容器数据的三条路" id="搬走容器数据的三条路"></a>

| 做法 | 结果 | 原因 |
|------|------|------|
| 复制到外置盘，原地留符号链接 | 应用能打开，但读不到数据；微信会报「存储位置不能使用」 | 沙盒检查的是链接**指向哪里**，指向容器外就拒绝。指向外置盘和指向桌面结果一样 |
| 符号链接 + Ad-hoc 重签名 | macOS 26 及以下能用；升到 27 后可能双击秒退（微信已确认，QQ 音乐仍能开） | 重签名把沙盒身份拆了，符号链接才"生效"。但它同时抹掉了应用和容器之间的归属关系，27 起系统要核对这层关系 |
| 把外置盘上的一个 APFS 卷挂载到原目录 | 正常，签名不动 | 路径没有离开容器，沙盒放行；数据在外置盘上会弹一次系统授权框，点允许即可 |

前两条已经在 macOS 27 上实测确认，第三条也是。原始日志见[实验记录：符号链接](../research/sandbox-symlink.md)和[实验记录：挂载点](../research/sandbox-mountpoint.md)。

## 重签名到底动了什么 <a href="#重签名到底动了什么" id="重签名到底动了什么"></a>

Ad-hoc 重签名（`codesign --force --deep --sign -`）会从应用里抹掉：

| 丢失的内容 | 后果 |
|------------|------|
| `com.apple.security.app-sandbox` | 应用不再以沙盒身份运行 |
| `com.apple.security.application-groups` | 读不到 `Group Containers` 里的共享数据 |
| `keychain-access-groups` | 读不到钥匙串里的登录态、数据库密钥 |
| Team ID | 系统核对"这个容器是不是你的"时对不上 |

应用不会当场出问题。它以普通进程身份去读自己的容器，macOS 26 及以下放行；27 上如果系统里已存有它旧签名的授权记录，就会因为"代码要求不匹配"被拒绝：

```
sandboxd rejected approval request from WeChat for kTCCServiceSystemPolicyAppData
  (/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files): denied
runningboardd: termination reported by launchd (0, 0, 65280)
```

同一台机器、同一个重签名过的微信：

| 系统 | 表现 |
|------|------|
| macOS 26.6.2 | 连续用了两天半，正常 |
| macOS 27.0 | 每次启动约 0.4 秒后退出 |

{% hint style="warning" %}
**"以前一直没事"不是安全的证据**

重签名后能正常用几周甚至几个月，问题只在下一次大版本升级时爆发，升级前后没有任何提示。而且原始开发者的证书不在你的电脑上，抹掉的授权没法再签回去，只能重装。
{% endhint %}

## 为什么从终端能打开 <a href="#为什么从终端能打开" id="为什么从终端能打开"></a>

排查时容易被这一点误导。系统按"责任进程"记账：从 Finder 或 Dock 双击时，应用自己是责任进程，用自己的身份申请权限，被拒；从终端或某个已有完全磁盘访问权限的程序里启动时，责任进程算在宿主头上，应用相当于借用了宿主的权限。

所以"终端里能起来"不算修好。判断标准只有 Finder / Dock 双击。

## 自查 <a href="#自查" id="自查"></a>

把 `/Applications/WeChat.app` 换成你要查的应用：

```bash
# 1. 签名身份
codesign -dv --verbose=4 /Applications/WeChat.app 2>&1 | grep -E "Authority|TeamIdentifier|Signature"

# 2. 授权（正常输出一段 XML；只有 Executable= 一行说明已被抹掉）
codesign -d --entitlements - /Applications/WeChat.app

# 3. 容器里有没有指向外置盘的符号链接
find ~/Library/Containers/<Bundle ID> -maxdepth 6 -type l -exec readlink {} \; 2>/dev/null

# 4. 复现一次，看系统有没有拒绝
open -a /Applications/WeChat.app; sleep 3
log show --last 1m --style compact 2>/dev/null | grep -iE "rejected approval request|deny\(1\) file-read-data"
```

| 观察结果 | 含义 |
|----------|------|
| `Signature=adhoc` 且 `TeamIdentifier=not set` | 已被重签名；打不开时需要重装应用 |
| 第 3 步有输出且指向 `/Volumes/...` | 容器里还有旧的符号链接，需要先还原 |
| 日志有 `kTCCServiceSystemPolicyAppData ... denied` | 正在被拒绝访问自己的容器（重签名导致） |
| 日志有 `deny(1) file-read-data /Volumes/...` | 沙盒拒绝跟随符号链接（数据在外置盘导致） |

两种日志可能同时出现，对应两个独立的问题，要分别处理。

## 修复 <a href="#修复" id="修复"></a>

顺序不能乱，否则重装完的应用看到的仍是符号链接，会误以为重装没用：

1. **还原容器数据**：在 AppPorts「应用数据」页把该应用所有「已链接」的容器目录逐个「还原」回本地。
2. **重装应用**：从官方渠道覆盖安装，恢复原始签名和沙盒。容器数据不会被重装删除。
3. **需要的话再挂载迁移**：重装后容器目录会显示「挂载迁移」，想继续放到外置盘就再迁一次。

新版 AppPorts 的「恢复原始签名」可以从完整备份恢复原应用，无需开发者私钥。旧版只有身份名称的记录需要选择同版本官方原版，或从官方渠道重装；详见[签名备份与恢复](resign.md#qian-ming-bei-fen-yu-hui-fu)。恢复签名前仍需先还原经典模式迁移的容器目录。

详细步骤和已迁移到外置盘的应用怎么处理，见 [macOS 27 升级说明](../macos-27.md#xiu-fu)。

## 真实案例 <a href="#真实案例" id="真实案例"></a>

2026 年 9 月，一台真实机器上的完整过程：

| 时间 | 事件 |
|------|------|
| 9/15 04:46 | AppPorts 把微信聊天数据目录迁移到外置盘，原地留符号链接 |
| 9/15 04:47 | AppPorts 对微信执行 Ad-hoc 重签名 |
| 9/16 至 9/18 | macOS 26.6.2 下微信正常使用两天半 |
| 9/18 04:46 | 升级到 macOS 27.0 |
| 9/18 起 | 每次启动约 0.4 秒后退出 |
| 9/18 05:04 | 用户还原数据并再次重签名，问题依旧 |
| 9/18 | 还原数据 + 从官网重装微信，恢复正常，聊天记录完整 |

数据从头到尾没有损坏。真正的埋伏是重签名，它在升级前没有任何症状。

## 相关文档 <a href="#相关文档" id="相关文档"></a>

- [macOS 27 升级说明](../macos-27.md)：升级前检查清单和修复步骤
- [挂载迁移](mount-migration.md)：新方案怎么用
- [为什么外置盘必须是 APFS](../why-apfs.md)
- [重签名与崩溃防护](resign.md)：重签名功能现在的边界
