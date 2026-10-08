# Container Data, Sandboxing, and Signing Identity

{% hint style="success" %}
**The key point**

Data in `~/Library/Containers/` and `~/Library/Group Containers/` belongs to **sandboxed apps**. Moving it to an external drive with a "shortcut" (symbolic link) makes it unreadable to those apps. AppPorts previously used re-signing to bypass this, at the cost of apps potentially failing to open on macOS 27 and losing login sessions.

Starting with 1.9.0, container data uses [mount migration](mount-migration.md), without changing a single byte of the signature. Apps that have already been re-signed need to be reinstalled; see [Upgrading to macOS 27](../macos-27.md).
{% endhint %}

This page explains the background. If your app already fails to open, go directly to the repair steps in [Upgrading to macOS 27](../macos-27.md).

## What Is a Container? <a href="#what-is-a-container" id="what-is-a-container"></a>

Most macOS apps run in a sandbox. The system assigns each app a dedicated folder, `~/Library/Containers/<Bundle ID>/`, and confines its reads and writes there. App Store apps must use this model, and apps downloaded from developers, such as WeChat and QQ Music, often use it too. Data shared by multiple apps lives in `~/Library/Group Containers/`.

To determine whether an app is sandboxed, look for `com.apple.security.app-sandbox` in its entitlements:

```bash
codesign -d --entitlements - --xml /Applications/WeChat.app 2>/dev/null | grep -c app-sandbox
# 输出 1 就是沙盒应用
```

An easily missed detail: **an unsandboxed main app does not mean its containers can be moved freely.** Chrome and Edge do not sandbox their main executables, but their widgets and extensions have containers owned by sandboxed processes. AppPorts therefore handles all directories under `Containers` consistently, regardless of the main executable.

## Three Ways to Move Container Data <a href="#three-ways-to-move-container-data" id="three-ways-to-move-container-data"></a>

| Approach | Result | Reason |
|----------|--------|--------|
| Copy to the external drive and leave a symbolic link | The app opens but cannot read the data; WeChat reports that the storage location cannot be used | The sandbox checks **where the link points** and denies targets outside the container. An external drive and the Desktop produce the same result |
| Symbolic link plus Ad-hoc re-signing | Works on macOS 26 and earlier; may quit immediately after upgrading to 27, confirmed for WeChat while QQ Music still opens | Removing the sandbox identity makes the link usable, but also removes the ownership relationship between the app and container, which macOS 27 checks |
| Mount an APFS volume from the external drive at the original directory | Works without signature changes | The path stays inside the container and passes the sandbox check. Allow the one-time system prompt for data on external storage |

All three approaches have been tested on macOS 27. Original logs are in [Experiment: Symbolic Links](../research/sandbox-symlink.md) and [Experiment: Mount Points](../research/sandbox-mountpoint.md).

## What Re-signing Changes <a href="#what-re-signing-changes" id="what-re-signing-changes"></a>

Ad-hoc re-signing (`codesign --force --deep --sign -`) removes the following from the app:

| Removed Item | Consequence |
|--------------|-------------|
| `com.apple.security.app-sandbox` | The app no longer runs with a sandbox identity |
| `com.apple.security.application-groups` | Shared data in `Group Containers` becomes inaccessible |
| `keychain-access-groups` | Keychain login sessions and database keys become inaccessible |
| Team ID | The identity no longer matches when the system checks container ownership |

The app does not necessarily fail immediately. It accesses its container as an ordinary process, which macOS 26 and earlier allow. On 27, if the system already holds permission records for its previous signature, access is denied because the code requirement no longer matches:

```
sandboxd rejected approval request from WeChat for kTCCServiceSystemPolicyAppData
  (/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files): denied
runningboardd: termination reported by launchd (0, 0, 65280)
```

The same re-signed WeChat app on the same Mac behaved as follows:

| System | Behavior |
|--------|----------|
| macOS 26.6.2 | Worked normally for two and a half days |
| macOS 27.0 | Quit about 0.4 seconds after every launch |

{% hint style="warning" %}
**"It always worked before" is not evidence of safety**

An app can work for weeks or months after re-signing, then fail at the next major system upgrade without any warning before or after it. The original developer's certificate is not on your Mac, so you cannot sign the removed entitlements back into place; reinstalling is required.
{% endhint %}

## Why It Can Open from Terminal <a href="#why-it-can-open-from-terminal" id="why-it-can-open-from-terminal"></a>

This can be misleading during diagnosis. The system attributes access to a "responsible process". When opened from Finder or the Dock, the app is responsible for itself and its own identity is denied. When started from Terminal or another program with Full Disk Access, the host is treated as responsible, effectively lending the app its permissions.

Opening successfully from Terminal therefore does not prove it is fixed. Test by opening from Finder or the Dock.

## Check It Yourself <a href="#check-it-yourself" id="check-it-yourself"></a>

Replace `/Applications/WeChat.app` with the app you want to check:

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

| Observation | Meaning |
|-------------|---------|
| `Signature=adhoc` and `TeamIdentifier=not set` | The app was re-signed; reinstall it if it cannot open |
| Step 3 produces paths pointing to `/Volumes/...` | Old symbolic links remain in the container and must be restored first |
| Logs show `kTCCServiceSystemPolicyAppData ... denied` | Access to the app's own container is being denied because of re-signing |
| Logs show `deny(1) file-read-data /Volumes/...` | The sandbox refuses to follow a symbolic link to external data |

Both log messages can appear together. They describe separate problems that need separate fixes.

## Repair <a href="#repair" id="repair"></a>

Keep this order. Otherwise the reinstalled app still encounters symbolic links and may appear unfixed:

1. **Restore container data**: in AppPorts "App Data", use "Restore" on each of the app's "Linked" container directories.
2. **Reinstall the app**: install over it from an official source to restore its original signature and sandbox. Reinstallation does not delete container data.
3. **Use mount migration if needed**: the restored container directories show "Mount migration". Use it if you want the data back on the external drive.

The new "Restore Original Signature" action can restore the original app from a complete backup without the developer's private key. Older records containing only an identity name require an official original copy of the same app version, or reinstallation from an official source. See [Signature Backups and Restoration](resign.md#signature-backups-and-restoration). Restore container directories migrated in classic mode before restoring the signature.

For detailed steps, including apps whose bundles were also migrated to an external drive, see [Upgrading to macOS 27](../macos-27.md#repair).

## A Real Case <a href="#a-real-case" id="a-real-case"></a>

The complete sequence on a real Mac in September 2026:

| Time | Event |
|------|-------|
| 9/15 04:46 | AppPorts migrated WeChat chat data to the external drive and left a symbolic link |
| 9/15 04:47 | AppPorts applied an Ad-hoc signature to WeChat |
| 9/16 to 9/18 | WeChat worked normally on macOS 26.6.2 for two and a half days |
| 9/18 04:46 | Upgraded to macOS 27.0 |
| From 9/18 | The app quit about 0.4 seconds after each launch |
| 9/18 05:04 | The user restored the data and re-signed again; the problem remained |
| 9/18 | Restoring data and reinstalling WeChat from its website restored normal operation, with chat history intact |

The data was never corrupted. Re-signing was the latent problem, with no symptoms before the upgrade.

## Related Documentation <a href="#related-documentation" id="related-documentation"></a>

- [Upgrading to macOS 27](../macos-27.md): checks before upgrading and repair steps
- [Mount Migration](mount-migration.md): how to use the new approach
- [Why External Drives Must Use APFS](../why-apfs.md)
- [Re-signing and Crash Prevention](resign.md): the current limits of re-signing
