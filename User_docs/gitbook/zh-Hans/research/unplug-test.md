# 实验记录：拔盘对 APFS 卷与磁盘映像的影响

本文是一次**受控实验**的原始记录，用来回答挂载迁移选后端时的一个问题：

> 把容器数据放在外置盘的 APFS 卷里，和放在外置盘上的 APFS 磁盘映像（sparsebundle）里，写入过程中直接拔盘，各自会丢多少？

结论是**磁盘映像在两轮测试中都整卷报废**，APFS 卷只丢最后几个事务。面向用户的解释见[为什么外置盘必须是 APFS](../why-apfs.md)。

## 环境 <a href="#环境" id="环境"></a>

| 项目 | 值 |
|------|-----|
| 系统 | macOS 27.0 (26A428)，arm64 |
| 测试盘 | 64 GB USB 闪存盘（U352），`diskutil eraseDisk APFS APTEST GPT` 后使用 |
| APFS 卷 | 在测试盘的 APFS 容器里 `diskutil apfs addVolume` 新建，`diskutil mount -mountPoint ~/appports-test/usb-apfsmnt` |
| 磁盘映像 | `hdiutil create -type SPARSEBUNDLE -fs APFS -size 20g`，存放在测试盘根目录，`hdiutil attach -mountpoint ~/appports-test/usb-imgmnt -nobrowse` |
| 写入负载 | Python 脚本：SQLite `synchronous=FULL` + WAL，循环插入并逐条提交，同时每 50 次提交写一个 64 KB 文件；每次提交写一行 `committed N` 到日志 |
| 拔盘方式 | 直接拔出 USB 接口，不弹出 |
| 日期 | 2026-09-19 |

## 第一轮：普通 fsync <a href="#第一轮-普通-fsync" id="第一轮-普通-fsync"></a>

两个写入进程并行 12 秒后拔盘。

| | 拔前最后一次提交 | 插回后 |
|---|---|---|
| APFS 卷 | 7177 | `yank.db` 报 `database disk image is malformed`；`sqlite3 .recover` 救回 7172 行，`max(id)=7172`；50 个文件全部在 |
| 磁盘映像 | 25574 | `hdiutil attach` 报"无可装载的文件系统"；`fsck_apfs` 报 `container superblock is invalid`；band 0 文件只有 3.26 MB（正常应为 8 MB） |

映像的提交数是卷的三倍多，说明它的写入基本停留在宿主的页缓存里，并没有落盘。

## 第二轮：`F_FULLFSYNC` <a href="#第二轮-f-fullfsync" id="第二轮-f-fullfsync"></a>

写入脚本加上 `pragma fullfsync=1; pragma checkpoint_fullfsync=1`，这是 SQLite 在 macOS 上真正强制写穿到介质的方式（多数应用不开）。两边都慢了很多。

| | 拔前最后一次提交 | 插回后 |
|---|---|---|
| APFS 卷 | 1906 | `integrity_check` = ok，1905 行，`max(id)=1905` |
| 磁盘映像 | 373 | 仍然无法挂载，超级块无效 |

即使应用层做到了最严格的落盘，映像内部 APFS 的检查点区域（落在 band 0）仍然处于半写状态。

## 第三轮：ASIF（已中止） <a href="#第三轮-asif-已中止" id="第三轮-asif-已中止"></a>

macOS 26 起提供单文件稀疏映像 ASIF（`diskutil image create blank --format ASIF`）。挂载后写入 12 秒、8000 次提交，尚未拔盘时决定中止：ASIF 只在 26+ 可用，对目标用户（12 至 26）没有意义，且它和 APFS 卷一样要求宿主是 APFS，解决不了 exFAT 的问题。

## 性能对照（拔盘前，同一块 U 盘） <a href="#性能对照-拔盘前-同一块-u-盘" id="性能对照-拔盘前-同一块-u-盘"></a>

| 负载 | 内置 SSD | APFS 卷 | sparsebundle（宿主 APFS） | sparsebundle（宿主 exFAT 映像） | 直接写 exFAT |
|---|---|---|---|---|---|
| SQLite 2000 次逐条提交 | 0.07 s | 0.35 s | 0.10 s | 0.17 s | 1.69 s |
| 2000 个 4 KB 小文件 | 0.08 s | 0.10 s | 0.08 s | 0.09 s | 0.76 s |
| 顺序写 256 MB + fsync | 0.07 s | 0.31 s | 0.37 s | 0.67 s | 0.80 s |

映像的数据库提交比 APFS 卷还快，正是因为它没有真正落盘。exFAT 那一列说明就算能在 exFAT 上直接放数据库，性能也不适合聊天记录这类负载。

## 其它观察 <a href="#其它观察" id="其它观察"></a>

- 映像方案**不触发**「可移动宗卷」TCC 授权：系统自带的便签（平台应用）在 APFS 卷上被静默拒绝，在映像上正常读写，日志没有任何 deny。
- 映像删除文件后空间不归还，5 GB 写入并删除后映像仍占 5.6 GB，需要 `hdiutil compact`。
- 拔盘后测试盘的两个 APFS 卷本身 `fsck_apfs` 均正常，损坏只发生在映像内部。

## 结论 <a href="#结论" id="结论"></a>

| | APFS 卷 | 磁盘映像 |
|---|---|---|
| 拔盘丢失范围 | 最后几个事务，数据库可修复 | 整卷 |
| 外置盘格式 | 必须 APFS | 任意 |
| TCC 授权框 | 首次一次 | 无 |
| 性能 | 原生 | 相当（因未落盘） |

AppPorts 因此只提供 APFS 卷后端。映像方案的其它优点不足以抵消"拔一次盘整卷消失"。

## 清理 <a href="#清理" id="清理"></a>

写入进程已停止，映像与测试卷已删除，`~/appports-test/` 已删除，用作对照的便签容器数据已原样恢复。测试盘保留为空的 APFS 盘。
