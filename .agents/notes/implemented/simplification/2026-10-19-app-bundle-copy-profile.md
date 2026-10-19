# Agent Note: 应用包迁移不再沿用数据目录的内容寻址校验

Status: implemented

## Problem

用户诊断包（AppPorts 1.9.2 build 40，APFS 加密外置盘）显示：Xcode.app 迁移在 `copy` 阶段耗时 **8100 秒（2 小时 15 分）**，期间日志完全静默，最后以 `Swift.CancellationError` 结束；Photoshop 2026 一次 19 分 40 秒的复制被判为"数据在操作期间发生变化或校验不一致"。13 次迁移尝试只成功 2 次，累计约 2.9 小时。

根因不是加密盘带宽。同一棵树（125 828 个文件）本机 `cp -R` 只需 70 秒，而复制器实测每文件 64 ms。`TreeCopySession` 引入时的头部注释写着 "App bundle migration continues to use FileCopier"，但 commit `6996349`（2026-10-12，实现 verified migration）把应用迁移也切到了严格复制器上，注释再未更新 —— 应用包被套上了为数据目录设计的内容寻址契约。

## Decision

`TreeCopySession` 接受一个 `TreeCopyProfile`，由调用方声明需要哪种内容证明。结构性安全两者完全相同：不跟随链接的锚定遍历、拒绝嵌套挂载、原子 rename 切换、验证通过前保留原件、逐节点取消检查与进度上报。

`.strictData`（数据目录，`TreeCopySession()` 默认）保持原契约：每文件 SHA-256 基线、时间戳严格比较、逐文件与逐目录 `fsync` 加根与目录的 `F_FULLFSYNC`。

`.appBundle`（应用包，`AppTransferTransaction.copyProfile`）只改变内容证明的形式：

- 清单**不记录**每文件 SHA-256。已签名应用自带发布方内容清单，`SecStaticCodeCheckValidity`（`kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode`）证明目标与开发者签名的字节一致，比"与五分钟前读到的一致"更强，实测 Xcode.app 14.7 秒。
- 时间戳漂移不单独判失败。`assertStable` 仍比较 inode、mode、size、link count；`compareEntry` 仍比较 path、kind、mode、uid/gid、flags、xattr、ACL、size、资源叉摘要、链接目标与硬链接组。
- `DurableFileIO.syncTree(barrier: .contentDurable)` 跳过逐文件 `fsync`，保留每个目录的 `fsync`。文件的名字与 inode 由其父目录的 fsync 提交；候选副本只有在自身校验通过后才被切换，掉电留下的是需要重做的目标，不是被切换到的目标。根与父目录仍走 `F_FULLFSYNC`。
- 目标文件系统无法表达的元数据被降级而不是拒绝：无 ACL 支持（ExFAT/FAT 对 `acl_set_fd_np` 一律返回 `ENOTSUP`，包括空 ACL）时跳过空 ACL；无硬链接支持时把共享 inode 物化为独立副本；无资源叉支持时丢弃资源叉；忽略 POSIX 权限位时不比较 mode。四项都由 `TreeCopyProfile` 的 `tolerates*` 开关控制，仅 `.appBundle` 开启。源侧**确实存在**的 ACL 写不进去仍然失败，多余元数据也仍然失败，因此真实复制错误不会被掩盖。
- `AppTransferTransaction.prepareCandidate` 保留一次 `verifyCopy`、`verifySignatures`、`syncTree` 与 `captureBaseline(candidate)`；删去的是此前对同一份字节的额外重复扫描。

**关键约束：删除路径必须使用与建立基线时相同的 profile。** `removeVerifiedCopy` 的 manifest 是删除授权的唯一依据，`verify(baseline:)` 与 `removeVerifiedCopy` 都显式传入 `Self.copyProfile`。二者不一致会让"有 digest 的扫描结果"去比较"无 digest 的基线"，这是本次实现中真实踩到的缺陷。

## Evidence

同一份 1.2 GB / 600 文件的树，两个 profile 各跑一次（本机 APFS SSD，`DataTransferSession` 分阶段计时）：

| 阶段 | `.strictData` | `.appBundle` | 变化 |
|---|---|---|---|
| scan | 0.495 s | 0.019 s | 26× |
| copy | 1.043 s | 0.877 s | 1.2× |
| verification | 0.983 s | 0.063 s | 16× |
| 合计 | 2.70 s | 1.00 s | 2.7× |

真实 Xcode.app（125 828 文件）的 scan 阶段：带 SHA-256 39.47 秒，不带 8.85 秒（4.5×）。独立测量显示 scan 中 SHA-256 占 96.8%，纯元数据仅 1.17 秒。

用户日志中 8100 秒的绝对值无法在本机复现：外置卷当前只读，无法建立可比较的延迟基线。因此上表是本机下限，不是对用户机器的预测；用户场景的收益应更大，因为每文件 64 ms 的代价主要来自慢盘上的逐文件 syscall 往返，而逐文件 `fsync` 与 SHA-256 正是被移除的那两项。

## Alternatives considered

- **只去掉逐文件 `fsync`，保留 SHA-256**：能改善 copy 阶段，但 scan 与两次 verification 仍是全量内容读取；实测 scan 的 96.8% 是哈希，收益被腰斩。
- **只去掉 SHA-256，保留逐文件 `fsync`**：copy 阶段的逐文件等待仍在，而它正是 8100 秒的主要构成。
- **彻底关闭应用迁移的校验**：会让"切换到一个未经验证的目标"成为可能，放弃的是本次改动唯一不能放弃的东西 —— 保留原件直到目标被证明可用。
- **把严格复制器整体降级**：会同时削弱数据目录，而那正是 `2026-10-01-data-path-copy-safety.md` 用真实事故（SQLite 源 3 行已 COMMIT、目标仅 1 行，两边 `integrity_check` 都 ok）建立的契约。
- **用 `clonefile`/`copyfile(COPYFILE_CLONE)` 重写复制**：跨卷时退化为真实复制，且仍要逐文件元数据回放；它优化的是同一卷内的场景，与用户的外置盘无关。

## Consequences

收益：应用迁移的 scan 与 verification 从全量内容读取降为元数据遍历，逐文件 `fsync` 的串行等待消失。对已签名应用，完整性证明由 `codesign` 提供，比自算哈希更强且更快。

代价与边界：

- 应用包迁移不再能证明"目标与源在迁移时刻逐字节相同"。它证明的是"目标与发布方签名一致"，以及"源在复制期间未被替换"（inode、size、mode、link count 仍在每次遍历中复核）。若某应用未签名或签名损坏，`signatureIsValid` 返回 false，该路径不做签名校验，此时只剩下元数据级证明 —— 这是本次放宽的真实缺口，接受它是因为未签名应用本来就无法通过切换前的签名检查。
- 掉电窗口从"每个文件都已落盘"收窄为"目录项已落盘"。候选副本在切换前会被完整校验，因此掉电的后果是需要重做复制，而不是切换到损坏的目标。
- 数据目录路径的契约、默认参数与调用点完全未变；`DataDirMover` 与 `ContainerVolumeMigrator` 仍调用无参 `TreeCopySession()` 与默认 `syncTree`。
- 时间戳容忍意味着一个在复制期间被改写且大小恰好不变的文件不会被发现。应用包场景下这由签名校验兜底；若将来出现未签名且可变的目录树，应改回 `.strictData`。
- 迁到不支持 ACL/硬链接/资源叉/权限位的盘时，这些元数据会丢失。硬链接分离与资源叉丢弃的次数由 `copy()` 在结束时以 WARN 记录一次（`目标存储无法保留部分元数据`），不会静默发生。实测 ExFAT 上 Developer ID 签名应用复制后 `codesign --verify --strict` 仍通过并可启动。

## 切换到目标盘的两个非原子降级

ExFAT/FAT 不支持 `renameatx_np` 的 `RENAME_EXCL` 与 `RENAME_SWAP`（两者都返回 `ENOTSUP`）。切换阶段原本完全依赖这两个原子操作，因此即使复制成功，最后一步仍会失败——这是端到端测试才暴露的，纯复制器测试发现不了。

`AppTransferTransaction.moveExclusively` 在 `ENOTSUP`/`EINVAL` 时降级为「检查目标不存在 + 普通 `rename`」；`exchange` 降级为「暂存一方 + 两次排他改名」。两者都保留「不覆盖已存在对象」的契约，但检查与改名不再是一个原子操作，中途崩溃可能留下 `.appports-swap-<UUID>` 临时名。其他错误码仍然直接抛出，降级只在文件系统明确表示不支持时启用。

## 用户可见的代价说明

迁移前会探测目标卷的真实能力（`StorageCapabilityProbe`：在目标位置临时建立条目，实际尝试写 ACL、写资源叉、建硬链接、设置权限位，再删除），缺失任一项时弹出 `WarningSheet` 列出具体缺什么，并提供「仍要迁移」与指向文档站 `storage-capabilities` 页的「详情请参阅文档」链接。探测而非按格式名判断，是因为同一文件系统在不同挂载选项下能力不同，而新格式会从名称开关里静默漏过。

放宽造成的元数据丢失同时写入日志（`目标存储无法保留部分元数据`，含 `hardlinks_split` / `resource_forks_dropped` 计数），因此提示、日志、文档三处都能解释同一次迁移的结果。

## Verification

`AppPortsTests/TreeCopySessionTests`、`TreeCopyOwnershipTests`、`AppTransferTransactionTests` 共 108 例通过；`MigrationSigningIntegrationTests`、`DataMigrationBackupCleanupTests`、`DataTransferRecoveryTests`、`DataTransferCompletionTests`、`AppMigrationServiceTests`、`AppListTransferTests` 共 60 例通过；`FileCopierTests`、`DataDirTreeTests`、`DataTransferProcessLockTests`、`DataTransferStoreTests` 共 43 例通过。Release 构建通过。

新增回归风险点：删除路径与基线 profile 必须一致。`AppTransferTransaction.remove` 与 `verify` 均显式传 `Self.copyProfile`，任一漏传会让清理失败并留下 `unclaimedPaths`，表现为"应用暂存目录待清理"。
