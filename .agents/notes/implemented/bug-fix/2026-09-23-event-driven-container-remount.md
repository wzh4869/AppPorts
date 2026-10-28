# Agent Note: 按卷事件重试并核实实际挂载位置

Status: implemented

> 迁移自合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/R/User_docs/docs/research/prelogin-mount.md（S078，冻结研究快照）
> 补充来源：同归档 / 原始报告快照/I/evidence/lifecycle-round3/offline/缺盘与挂载恢复实验报告.md（S020）。

## Problem

登录或插盘时，系统自动挂载与代理查询存在竞态。`diskutil mount -mountPoint` 返回 0 时卷可能仍在原 `/Volumes` 位置，目标入口为空；失败后直接退出会把临时竞态变成持续不可用。等待卷期间占有操作锁，还会阻塞其他合法操作。

## Decision

代理按“取锁、尝试、放锁、等事件、再尝试”运行。`VolumeChangeMonitor` 监听 `/Volumes` 目录本身的变化，等待安静窗口后重查，监听对象 inode 变化时重新打开；缺少事件时仍作兜底检查。`ContainerRemountLoop` 的 180 秒、最多 20 轮是卷到达的等待窗口，不是完整数据恢复的总期限。

挂载成功以实际路径、挂载状态与卷 UUID 为准，不以退出码为准；路径规范化使用 realpath 处理 `/tmp` 与 `/private/tmp` 的差异。卷已被自动挂到别处时，核对身份和落点后重新挂载，目标未就位继续有限重试。

已知自动挂载位置可用 statfs、卷标记和实际卷 UUID 走快路径；名称或可复制的标记本身不能授权卸载。不满足身份条件时回退完整查询，不把同名卷认作自己的数据。

登录代理需要可用的用户会话、已解锁的 Data 卷和正确身份的权限。root 守护进程不绕过 FileVault 或 TCC/FDA，也可能读取自己的空记录库；不承诺固定开机秒数或永远早于应用启动。底层落点存在新内容时保留冲突，不能为赶上挂载而覆盖。

## Related decisions

- 旧卷的挂载所有权选择见[旧容器重连保持原有所有权语义](2026-10-07-legacy-container-remount.md)。
- 180 秒等待与已移除的整项恢复总期限分开，见[由持久化事务自动完成 APFS 恢复与清理](../../implemented/architecture/2026-10-12-apfs-automatic-recovery.md)。
- 执行者权限与目标应用权限见[按当前任务进行 APFS 迁移预检](../feature/2026-09-24-apfs-migration-preflight.md)。


主动弹出后的暂停准入和真实重连接恢复见[主动弹出外盘时暂停恢复挂载](../feature/2026-10-23-explicit-disk-ejection.md)。

同目录手动卸载的持久暂停见[保留单卷卸载意图并补齐旧软链接管](2026-10-28-manual-unmount-and-link-adoption.md)。

## Alternatives considered

- **相信 diskutil exit 0 后结束**：命令接口最简单，但已挂载卷可以忽略新的 mountPoint，成功码并未证明入口恢复。
- **只作固定延时或一次重试**：不用目录监听，却无法跟随真实卷出现时机；采用事件加兜底检查，并在等待期间释放锁。
- **root 守护进程保证登录前挂载**：可避开部分用户代理调度，却仍受解锁、会话和授权条件限制，并增加系统组件；来源不支持把它作为通用保证。

## Consequences

插盘竞态可以被后续事件纠正，等待不会长期持有操作锁。代价是维护事件去抖、监听重建和真实身份校验；系统忙、授权缺失或底层新内容仍会阻止重挂。某次应用先启动但没有写入空入口，不证明任何应用都不会产生数据分叉。

## Verification

归档记录临时 APFS 卷事件到达后的代理重挂及七种预先挂载延时对照；极窄的“查询后才自动挂载”分支由 fake runner 覆盖，未在该轮实机主动复现。`ContainerRemountLoopTests`、`ContainerVolumeMigratorTests` 和 `ContainerMountAgentTests` 提供回归入口。历史登录时序只属于当时构建；此次不重启或安装代理。
