# Agent Note: 迁移副本不再回放或校验 quarantine

Status: implemented

## Problem

2.1.0 (51) 在 macOS 27.2 上把带 quarantine 的应用迁往外置盘 100% 失败：
复制完成后 verifying 阶段对副本文件报 `NSPOSIXErrorDomain 13`，重试全部命中
同一路径。微信 4.2.0（Sparkle 更新，`0082;…;` 系统发起型）和 RedPot.app
（Edge 下载，`01c1;…;` 尚未清除）都复现；历史成功副本（QQ、Edge、ChatGPT）
的源文件在用户打开后已被系统清除 quarantine。

排查确认三层事实：副本复制后由系统自动附加 quarantine（复制路径为
pread/pwrite，代码未写入）；所有进程对该副本的 `removexattr` 均被
macOS 27 拒绝（EACCES，含创建进程与 hardened 签名进程）；带 bundle 的
hardened 进程对该副本的 open、pread、fgetxattr、
`SecStaticCodeCheckValidity` 全部正常。因此失败点唯一：
`AppTransferTransaction.prepareCandidate` 复制完成后的 quarantine 移除循环
调用 `removexattr` 抛出 EACCES，整个迁移被一个无害元数据标记终止。

## Decision

- `TreeCopySession.systemManagedAttributes` 增加 `com.apple.quarantine`：
  清单不记录、比较不参与、`applyMetadata` 不回放。与该文件对
  provenance/macl 的既有处理及 FileCopier 的 `removeQuarantine` 语义对齐。
- `prepareCandidate` 的移除循环对 EACCES/EPERM 降级为 WARN 日志并继续，
  仅其他错误仍然失败。副本保留已获系统批准（0082）的 quarantine 标记
  不影响启动与签名验证，为此终止迁移得不偿失。

## Alternatives considered

- **验证失败走管理员授权重试**：PrivilegedAppTransfer 是动作级 helper，
  覆盖不了树扫描内的单文件元数据调用，且重试仍会命中同一个系统拒绝。
- **先清源再复制**：删除源的 quarantine 同样被系统拒绝，且会改动
  用户正在使用的原始应用，超出迁移工具的边界。
- **保留 throw，仅提示用户**：Sparkle 更新过的应用在 macOS 27.2 上
  全部不可迁移，问题会随更新扩散到更多应用。

## Consequences

外置盘上的迁移副本此后可能携带 quarantine 标记，与 QQ/Edge 等
历史副本的"无标记"状态不同。该标记记录的是源应用已被批准的来源，
Gatekeeper 对副本按已批准处理；若 macOS 未来对无管理授权进程读取
此类副本收紧，需要重新评估（当前同证书 hardened 探针实测读取正常）。
清理路径对旧版清单（记录过 quarantine）与过滤后扫描的比较仍会报
extended_attributes 差异并保留副本，属安全行为，由既有重试消化。

## Verification

- `AppPortsTests/TreeCopySessionQuarantineTests.swift`：清单注入
  quarantine 后 `verifyCopy` 通过，注入普通应用属性仍失败，防止修复
  滑向"忽略全部属性差异"。
- `FileCopierTests`、`AppTransferTransactionTests`、`DataPathPolicyTests`
  共 101 项全部通过。
- 本机（QBJ8 Apple Development 签名 + hardened runtime 的 Release 构建）
  真实迁移 WeChat.app 1.53 GB：19:14:06 完成入口切换，本地 stub 指向
  `/Volumes/SanDisk/Applications/AppPorts.noindex/WeChat.app`，两侧列表
  均显示"已链接"，任务中心清空后无遗留。
- 同一构建真实迁移 RedPot.app 137 MB：入口切换完成，两侧均显示"已链接"；
  旧本地副本因归属复核未通过按既有策略保留在
  `/Applications/.appports-entry-ED1CF64D-BD4F-4438-A71E-0E67BD7C0F78`，
  不影响应用运行。
