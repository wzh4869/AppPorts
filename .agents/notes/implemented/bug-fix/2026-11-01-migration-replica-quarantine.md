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
  清单不记录、比较不参与、`applyMetadata` 不回放，也不主动删除目标上的标记。
  这与该文件对 provenance/macl 的既有处理一致，适用于应用、普通数据和容器复制。
- `prepareCandidate` 直接使用复制器返回的清单校验副本。清单已不含 quarantine，
  因此删除标记的循环没有处理对象，`withoutQuarantine` 转换也无作用，两者均移除。
  副本校验、原有签名校验、同步、记账、入口切换与恢复清理流程保持不变。

## Alternatives considered

- **验证失败走管理员授权重试**：PrivilegedAppTransfer 是动作级 helper，
  覆盖不了树扫描内的单文件元数据调用，且重试仍会命中同一个系统拒绝。
- **先清源再复制**：删除源的 quarantine 同样被系统拒绝，且会改动
  用户正在使用的原始应用，超出迁移工具的边界。
- **保留 throw，仅提示用户**：Sparkle 更新过的应用在 macOS 27.2 上
  全部不可迁移，问题会随更新扩散到更多应用。

## Consequences

迁移副本可能携带系统附加的 quarantine 标记，AppPorts 不保证复制源标记，
也不主动清除目标标记；是否允许打开仍由 macOS 判断。下列两款应用的实机结果
由 PR 作者提供，不能据此断言任意来源、任意标记状态的文件均已获系统批准。
旧版清单即使记录过 quarantine，比较时也通过 `portableAttributes` 过滤，
不会仅因这个标记而报 extended_attributes 差异。其他要求保留的属性、内容、
身份或权限发生差异时，既有校验仍会拒绝继续或保留待清理副本。

## Verification

### 本地清理验证

- macOS 27.0.1、Xcode 27.0：arm64/x86_64 Release `xcodebuild clean build` 通过。
- 独立测试宿主执行 `AppMigrationServiceTests` 61 项、`AppTransferTransactionTests` 76 项、
  `ContainerVolumeMigratorTests` 93 项、`DataDirMoverTests` 50 项及 quarantine 回归 1 项，
  共 281 项通过（含参数化用例共执行 325 次），没有失败或跳过。
- `MigrationSigningIntegrationTests` 使用外置 APFS 卷上的独立 UUID 样本目录，3 项通过：
  签名应用迁移和元数据保留、拒绝重签沙盒应用、应用及聊天数据库/附件往返；迁移后新增
  数据库记录在迁回后仍存在。样本不使用已安装应用或真实聊天数据。
- 本次未跑全量测试，未实测真实容器挂载/卸载，也未复现作者 macOS 27.2 的真实应用场景。
  原始构建和测试结果位于 `/tmp/AppPorts-PR103-cleanup.QujOj8/`。

### PR 作者提供的验证

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
