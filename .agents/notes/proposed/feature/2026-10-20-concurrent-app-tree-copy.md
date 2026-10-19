# Agent Note: 同层并发复制应用树

Status: proposed

## Problem

应用迁移在慢速外置盘上仍要花数小时。日志里 Xcode.app（125,828 文件）的复制阶段耗时 8,100 秒，折合每文件 64 ms；而同一棵树在本机内置 SSD 上实测仅 0.4 ms/文件。**160 倍的差距来自每一次 syscall 都要等设备往返**，不是来自算法。

当前 `TreeCopySession.copyNode` 严格串行：每个文件依次 open/read/write/close 并回放元数据，前一个 syscall 返回后才发下一个。在延迟主导的设备上，这意味着总耗时 ≈ 文件数 × 单次延迟。

已尝试并排除的方案：`copyfile(COPYFILE_ALL|COPYFILE_RECURSIVE|COPYFILE_CLONE)` 实测在 120,000 文件树上 29.6s，仅比当前实现（48.0s）快 1.6 倍，因为 libcopyfile 内部同样逐文件串行；而且它会**静默把硬链接拆成独立副本**（源 2 links → 目标 1 link），即使加了 `COPYFILE_CLONE` 也一样。收益不足以抵偿这个已知缺陷。

## Proposal

把「同层文件」的复制并发化，**目录仍然串行下钻**。并发只发生在同一目录的直接子文件之间，因此：

- 递归结构不变，`copyNode` 仍是深度优先
- 目录句柄数量仍由树深决定，不会随文件数增长
- 硬链接只需在同层内保序（第一个复制、后续 `linkat`）

目标形态：

```swift
case .directory:
    // 目录先建好，再并发复制同层文件，子目录仍串行下钻
    let children = (context.index.children[path] ?? []).sorted()
    let files = children.filter { isRegularChild($0) }
    let dirs  = children.filter { !isRegularChild($0) }
    try await Self.copyFilesConcurrently(files, ...)
    for child in dirs { try await copyNode(path: child, ...) }
```

并发度需要可配置，并且**默认值必须保守**：慢盘上过多并发会加剧寻道争抢，而快盘上并发度过低没有收益。建议按目标卷类型选择（本机 APFS 取 4，外置/网络取 8），并在实测后确定。

## Open questions

- **并发度怎么定**：固定值、按卷类型、还是按实测延迟自适应？需要在外置盘上跑 1/2/4/8/16 各一档，取拐点。
- **`RLIMIT_NOFILE` 上限**：并发 N 路时同时持有 N 个文件描述符加目录链。需要测量或用 `getrlimit` 选并发度。
- **硬链接的跨目录情形**：同层保序只覆盖「同一目录内的链接组」。跨目录的硬链接组（Parallels 有这种）仍要靠串行下钻保证顺序——需要确认这是否会让并发的收益打折。
- **进度与取消语义**：并发后 `copiedBytes` 需要原子累加，取消要能中断在途任务而不只是不再发新任务。
- **错误传播**：一个文件失败后，其余在途任务需要等待结束再抛错，否则上层会在清理时遇到仍在写入的目标（现有串行实现有同样的顾虑，`FileCopier` 里已有先例可循）。

## Alternatives considered

- **换成 `copyfile(COPYFILE_RECURSIVE)`**：实测仅 1.6 倍，且静默丢硬链接，见 Problem。
- **整棵树全部并发（含目录）**：收益略高，但目录句柄随文件数增长，深树容易撞 `RLIMIT_NOFILE`，且父目录必须在子项之前存在，会引入无谓的同步复杂度。
- **改用 Swift Concurrency 的 TaskGroup 替换手写线程**：`copyNode` 是 actor 内的同步阻塞 I/O，混入 Swift Concurrency 反而需要 `Task.detached` 包裹，不如在同步路径上用 `DispatchQueue.concurrentPerform` 直接。
- **保持串行，只优化 syscall 数量**：需要逐项审计哪些元数据回放可以合并（例如用 `fsetattrlist` 一次设多个属性），收益未知且改动面更大，留作后续。

## Acceptance criteria

- 本机 120,000 文件合成树上，锁定时长对比串行基线，收益可复现
- 外置慢盘（或模拟高延迟卷）上收益显著高于本机；若相反则说明假设错误
- 硬链接：`Parallels Desktop.app` 这类含跨目录硬链接组的树，迁移后 `st_nlink` 与源一致
- 所有现有测试通过，包括 `TreeCopySessionTests`、`TreeCopyOwnershipTests`、`AppTransferTransactionTests`
- 取消在并发中途生效：点取消后不超过一个文件的时间窗口内停止
- 失败清理：一个文件失败后不会留下仍在写入的半成品
- ExFAT 端到端测试（`ExFATMigrationE2ETests`）仍通过

## Risks

- **并发下的硬链接正确性**：最容易出错的地方。同层内需要保证「被 `linkat` 指向的那个文件已经写完」，否则会链接到半成品。
- **fd 耗尽**：Xcode.app 有 29,868 个目录，深度可能几十层，并发加剧 fd 占用。
- **慢盘上反而更慢**：并发提高寻道争抢，机械盘（HDD）上可能负收益。需要按卷类型区分。
- **难度提升**：`copyNode` 是唯一同时处理数据分叉、资源叉、元数据、硬链接、FIFO、符号链接的函数，并发化会同时触碰全部路径，测试覆盖必须跟上。
