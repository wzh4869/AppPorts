# Agent Note: 位置变更统一清除旧版更新保护锁，并让卡住的转移记录可收尾

Status: implemented

## Problem

1.9.0 在迁移自更新应用时用 `chflags -R uchg` 递归锁住外部副本，但不记录锁了哪些对象；1.9.1 改为 `AppUpdateProtectionStore` 只撤销「自己记录过」的不可变位，并明确永不接管已存在的锁。升级用户的外部应用因此成了没有任何记录的锁：迁回时 `captureProtectionRecovery` 返回空 token，没有东西被解锁，`TreeCopySession.validateFlags` 直接在复制前拒绝 `UF_IMMUTABLE`，报「无法完整保留此项目的内容或权限」并留下 `phase=copying` 的 journal；重试重复同一结果。

同一版本还有两处收尾缺口放大了后果：`AppTransferStore.remove` 先删校验清单再删记录，中断后留下永远无法再验证、也无法自行完成的记录，永久占用该路径；`OperationMaintenance` 对每条 journal 无条件重试，对象已被替换时每次都抛同样的身份错误，用户既看不到可操作的原因，也没有放弃入口，只能手改 `~/Library/Application Support/AppPorts/app-transfers`。

Issue #77 的两条报错分别来自这两条链：VideoFusion 是旧锁（`unsupportedMetadata`），微信是「journal 已留存 + 外部对象被替换」的身份错误。

> 后继决定：[后台迁移任务与异常处理](../architecture/2026-10-21-后台迁移任务与异常处理.md)增加用户主动归档和强制回迁，部分替代本篇“没有用户恢复入口”的决定。下文保留自动收束方案的理由；旧锁接管与普通自动清理约束继续有效。

## Decision

**位置变更统一清除不可变位，不再判断锁的来源。** 应用更新锁是 AppPorts 自己的保护机制，1.9.0 用 `chflags -R uchg` 写入却没有记录。任何试图区分「哪些位是我们设的」的做法都会挡住正常迁回：应用在锁定之后更新或修复过，就会只保留部分标志——可能只剩根、也可能根已解锁而子项还锁着。所以位置变更时按整棵树清除 `UF_IMMUTABLE`，只清这一位，其它标志一律不碰。

`AppUpdateProtectionStore.adoptLegacyLock(_:evidence:)` 保留「先落盘、再解锁」的顺序和记录本身，但不再需要来源证明：它列出树里所有带不可变位的节点，写成记录（`adoptedLegacyLock: true`，旧记录缺该字段时按 `.managed` 解码），再交给既有的 suspend / commit / forget 走完。记录的作用是中断后能重放同一批位、取消时能还原；没有锁的树不产生记录。`evidence` 参数只用于日志，不再是放行条件。

对子目录的判断同样不再看根：`adoptLegacyLockIfNeeded` 直接扫描整棵树，因此「根未锁、子项锁定」这种被更新破坏过的形态也能迁回。其余标志位仍不被接管，验证复制的 fail-closed 校验照旧生效。

**journal 由维护流程自动收束，不进入用户界面。** `retryDisposition(for:)` 从磁盘事实判定：缺校验清单、外部对象已不在原位或身份不符时返回 `.terminal`，否则 `.retry`。维护流程先重试所有能推进的记录，再调用 `retireUnrecoverableTransfers()` 把无法推进的记录归档到 `app-transfers/archived/`，只动记录与清单，应用、保留副本、`.appports-transfer-*` 暂存对象一律留在原处。

这一步最初被做成一个「未完成的应用操作」面板，让用户自己选择重试、取消或结束。实测否决：面板把「应用已迁移完成、只剩删旧副本」这种内部收尾也列出来，而这类记录既不能取消（位置已切换）也不该结束（否则副本永久失去追踪），界面上只剩两个按不动的按钮。更根本的是，卡住的记录只有两种结局——完成，或放弃并保留一切——两者都不需要只有用户才知道的信息。把决定交回去，等于把它变成用户的作业，而用户此时连该做什么都无法判断。现在界面上没有任何入口，用户不需要知道这张记录存在过。

已切换位置的记录永不收束：它剩下的工作是按自己的校验清单删除旧副本，重试就是安全做法。

`AppTransferJournalIntegrity` 让所有恢复入口在读清单前给出同一条可操作错误，而不是抛裸 `ENOENT`。

**`remove` 先删记录再删清单。** 记录是权威，残留清单不被任何读取路径使用；反过来则会制造无法完成的记录。

## Alternatives considered

**按来源证据决定是否接管**（本笔记初版的做法）。要求「本地入口仍解析到该外部包」并只接受整棵树一致锁定的形态。理由是不清掉用户的 Finder 锁。实测否决：真实用户的树在锁定后被应用更新破坏成「只锁根」或「只锁子项」，一律被拒，迁回直接失败——错误信息让用户「明确解锁后重试」，而用户根本不知道自己何时锁过。锁是 AppPorts 自己加的，判断归属的成本最终由用户承担，收益却是保护一个它自己制造的状态。改为统一清除不可变位。

**统一递归 `chflags -R nouchg`（外部进程）后再复制**。仍被否：绕过记录与身份校验，且会连带清掉其它标志位。当前的统一解锁只清 `UF_IMMUTABLE`，其余标志继续 fail-closed。

**在 1.9.0→1.9.1 升级时一次性迁移锁状态。** 升级那一刻拿不到 1.9.0 的锁清单（它本来就没记录），只能靠猜测；而且用户可能跨版本、跨机器搬盘，升级脚本不能覆盖已存在的安装。改为按需接管，每次操作都带上当时的来源证据。

**把旧锁记录成普通 `.managed`。** 两种来源的授权强度不同：`managed` 是 AppPorts 自己设的位，`adoptedV1_9_0` 是从磁盘既有状态推断的。合并成一种会让后续代码无法收紧接管条件，也让诊断丢掉了这个区分。

**给 journal 加超时或重试上限后自动放弃。** 超时是任意阈值，会在真正能恢复时抢先把记录处理掉。当前是「按磁盘事实判定不可能再推进」才收束，并保留全部副本，不是放弃追踪。

**把未完成记录列给用户，让用户判断哪条要处理。** 第一版就是这样（先全量展示，再缩小到「重试也无法推进」的记录）。两次都被否决。全量版让用户看到一条已迁移完成的 Clash Verge 记录，被告知「这次操作已经产生了副本」，而界面上既没有取消按钮、结束记录又被拒绝。缩小版把用户能做决定的范围限到了最小，但仍然是一个只有代码能判断的问题：维护流程本来就知道这条记录还能不能推进，也本来就能安全地归档它。给用户一个按钮，只是把机器已经知道答案的问题转嫁出去。

**允许 `discardTransfer` 直接删除所有副本。** 会把「结束记录」变成数据删除操作，且无法区分哪些副本已被验证。当前只归档账本，删除仍走既有的校验清理路径。

## Consequences

收益：任何形态的旧锁都不再挡住迁回，用户不用手改 plist、不用手动 `chflags`，也不会再看到「锁定来源无法确认」这种他无从处置的提示。无法推进的 journal 由维护流程自行归档并解除路径阻塞，`remove` 顺序修正后不再产生永久占位的记录，界面上没有任何需要用户干预的应用位置状态。

代价：用户自己在访达里锁定的外盘应用，迁回时也会被解锁。这是明确接受的取舍——无法区分两者，而误挡真实迁回的代价更高；需要在迁回后保持锁定的内容应由用户重新设置。`archived/` 目录只增不减，需要用户自己在访达里清。旧 journal 里的空保护 token 会在恢复时重新接管一次，因此 1.9.1 期间失败过的记录仍可救回。

## Testing

应用包外的更新缓存锁收尾见[解除迁移锁时清除应用缓存锁](2026-11-16-解除迁移锁时清除应用缓存锁.md)。迁回、非锁定迁移与显式解除同时处理该应用的标准缓存目录，包内旧锁接管、原内容保留及转移取消保护继续沿用本篇规则。

回归测试在 `AppPortsTests/AppTransferTransactionTests.swift`（issue #77 分组）：`testEveryLockShapeIsClearedOnRestore` 覆盖全树锁、只锁根、只锁子项、部分锁定四种形态，都要求迁回成功且还原后不带锁；`testNonImmutableFlagsStillFailClosed` 断言额外标志位仍被拒绝且不动原树；`testCompressedSourceIsReadSequentiallyNotByPhysicalExtent` 用假 extent 探针断言压缩源从不走物理块路径；`testCompressedFlagIsAcceptedWhileOtherFlagsStillFailClosed` 断言压缩可复制而 `UF_APPEND` 仍拒绝；原 `testCompressedFlagFailsClosedBeforePayloadRead` 改名为 `testUndecodableCompressedStreamStillFailsClosed` 并改为断言逻辑字节被正确读出；1.9.0 全树锁 + 无记录 + 无 journal 时迁回成功且不留记录；排除外盘索引接管后仍锁新位置；被替换的外部对象被判为 `.blocked` 并可结束记录、两侧副本都在；清单丢失时给出可操作错误、结束记录后迁回成功；旧格式记录无 `adoptedLegacyLock` 时按 `.managed` 解码。

自动收束的契约各有专门用例：`testCommittedTransferCleanupRetriesInsteadOfAskingTheUser` 造出「迁移已完成、删旧副本失败」的记录，断言它被判为 `.retry`、不被收束、重试能正常收尾；`testUnrecoverableTransferIsRetiredAutomaticallyKeepingCopies` 造出「外部对象已被替换」的记录，断言维护流程自动归档记录、两侧副本都保留、路径随后可用；`testRetirementLeavesRecoverableRecordsAlone` 断言还能推进的记录不会被收束；`testJournalWithoutManifestsIsRetiredAutomatically` 覆盖清单丢失的记录。

**同一轮还修掉了一个更底层的复制缺陷。** `TreeCopySession` 用 `SEEK_DATA`/`SEEK_HOLE` 按物理盘块复制文件，而 macOS 会透明压缩已安装的可执行文件（`UF_COMPRESSED`，App Store 安装与长期未用的二进制）。对压缩文件 `SEEK_DATA` 返回 `ENXIO`，整文件被当成空洞，复制出来的是压缩流而非内容，校验必然失败；此前的对策是整体拒绝，代价是一个应用里只要有一个压缩文件就迁不回来。现在的做法是：接收 `UF_COMPRESSED`，`FileDataCopyStream` 对这类源跳过 extent 快路径、改用普通顺序读取（内核在 read 时解码），目标存为逻辑字节。实测 572 MB 应用完整复制，压缩文件哈希与原件一致、副本可执行。其余标志位仍 fail-closed。

另用独立 harness（链接 Debug 构建的 `.o`，绕过本机 `xcodebuild test` 的 PTY 限制）跑了 9 组场景共 40 项断言，含维护流程不再重复抛身份错误、归档目录保留、取消后入口完好。`xcodebuild build`（Debug 与 Release）通过；本机另有 12 个与本改动无关的既有失败（`Bundle.main` 资源、setgid、sponsor 缓存），已用 HEAD 基线复核不是本改动引入。

新增文案在面板被撤销后只剩维护流程自己使用的日志文本，用户界面没有新增字符串；`LocalizationAuditTests` 10/10 通过。
