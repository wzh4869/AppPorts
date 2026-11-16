# Agent Note: 所有权测试镜像仅对忙碌卸载做有限重试

Status: implemented

## Problem

提交 87b6bd9 的 CI 在 TreeCopyOwnershipTests.partialCleanupAfterReconnect 中，
hdiutil detach 返回 Resource busy，夹具立即记录失败。日志没有记录占用者，
无法区分短暂系统访问与持续泄漏；本次失败并非 latest.json 日期解析失败。

后续[build 67 的 runner](https://github.com/wzh4869/AppPorts/actions/runs/43885579492/attempts/1)
在兼容性校验测试清理阶段返回 No such file or directory，lsof 确认目标目录已经不是文件系统。
私有 APFS 镜像复现显示：diskutil unmount 后，按挂载目录执行 hdiutil detach 会同样失败，
但 hdiutil info 仍列出该镜像的设备。目录路径无法继续标识仍连接的镜像。

## Decision

OwnershipTestImage 的正常卸载最多尝试五次，仅对未超时的 EBUSY 退出码重试，
间隔为 250、500、1000、2000 毫秒。成功后才更新 attached 状态；其他错误、
超时和取消不重试。最终失败时采集有输出和时间上限的 lsof 卷占用信息，
仍然让测试失败，并保留未卸载镜像。夹具不使用 force，不跳过重连后的内容验证。

挂载使用 hdiutil attach -plist，记录本次镜像返回的整盘设备号，正常卸载以该设备为目标；
卷先被卸载时也能分离仍连接的镜像。设备号只来自该夹具私有镜像的挂载结果，成功分离后清空，
重挂时重新记录。尚未完成结果解析的失败准备阶段保留挂载目录回退，不忽略解析或卸载错误。

注入命令执行器和等待函数验证重试边界，真实镜像用例继续验证完整的断开、
重连和清理流程。此改动不改变生产迁移或卸载策略。

## Related decisions

检索活跃笔记后，[所有权兼容](../architecture/2026-10-09-data-ownership-compatibility.md)、
[测试状态隔离](2026-10-01-test-state-isolation.md) 和
[APFS 验证](2026-10-12-apfs-validation-evidence.md) 与本篇部分重叠，仍各自有效；
建卷与历史还原笔记不涉及夹具重试，无需替代或归档。

## Alternatives considered

- 单次卸载：失败最快，但把短暂占用直接变成整个回归失败，且没有占用诊断。
- 强制卸载：能驱逐占用者，但会掩盖真实资源泄漏，也不再验证正常断开流程。
- 只重跑整个测试：容易实施，却重复迁移且丢失首次占用现场；只重试卸载更窄。
- 继续按挂载目录卸载：不需要记录设备号，但卷已卸载时目录不能标识仍连接的镜像；
  使用挂载结果提供的设备号，不把“目录不再挂载”直接当成镜像分离成功。

## Consequences

短暂忙碌可恢复，持续占用仍暴露；代价是最多增加四次命令与 3.75 秒等待，
最终诊断另有五秒上限。占用者可能在诊断前退出，lsof 也可能权限不足，
因此诊断不能保证找到原因，不能把重试通过解释为已证明没有资源泄漏。

## Verification

2026-10-15 本机 macOS 27.0.1 的修改前定向用例通过，未稳定复现 CI 忙碌。
修改后 `TreeCopyOwnershipTests` 与 `OwnershipImageDetachTests` 共 13 项测试通过，
包括真实 APFS 镜像重连和五组注入结果的重试边界、等待取消。CI 当时占用者
仍未知；新增诊断用于下次持续失败取证。生产迁移实现保持不变。

2026-11-16 的本机修复前专项实际执行 1 项并失败，错误与 runner 的清理错误相同，
随后只读查询确认该私有镜像仍连接。新增真实 APFS 回归保留卷卸载后的清理路径，
原有忙碌、持续错误、超时及取消边界测试不变。复现遗留镜像按 image-path、设备号、
目录归属和 inode 核验后正常分离，确认镜像不再登记且目录无打开文件后删除，没有归档。
最初未带 Swift Testing 方法括号的定向过滤没有执行用例，不作为通过证据。

修复后本机专项通过：MainWindowAppearanceTests 两项 XCTest、TreeCopyOwnershipTests 与
OwnershipImageDetachTests 共 14 项 Swift Testing，0 失败。真实“卷先卸载、镜像后分离”用例通过，
busy、持续错误、其他错误、超时和取消结果保持原边界；全量 runner 结果另行记录。
