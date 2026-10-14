# Agent Note: 隔离 APFS 验证与可比较的性能证据

Status: proposed

> 迁移自 docs/superpowers/reports/2026-10-12-apfs-automatic-recovery-validation.md
> 迁移自 docs/wechat-incident-2026-10-12.md
> 迁移自 docs/apfs-lifecycle-validation-2026-10-12.md
> 迁移自 docs/apfs-wechat-validation-2026-10-13.md
> 迁移自 docs/apfs-cross-app-validation-2026-10-14.md

> 入库状态：本机已有实现与来源报告所述验证，相关源码尚未提交；按已确认的迁移约定暂记 proposed，随对应代码提交再转换。

## Problem

普通临时目录或镜像成功没有覆盖真实物理盘权限和受 TCC 保护的底层路径。把旧构建测速、单卷卸载、文件散列或测试宿主启动分别当成新构建性能、断电恢复、完整元数据与生产启动证明，会给出错误的交付结论。

## Proposal

测试分为模拟命令故障注入、持久化冷启动回归、独立身份宿主的私有 APFS 镜像，以及获得明确授权的真实应用流程。镜像与卷操作必须核对创建凭据、容器及 UUID，禁用生产记录和代理维护；失败保留现场，清理只针对可证明归属的产物。

性能对照固定 v1.9.0 源码和工具链，两版使用相同确定性数据、预读与交叉顺序，保留每轮准备、扫描、复制、校验、切换、清理和总时间。容量回收在计时区之外查询确认身份的 APFS 容器 CapacityFree，不用可能滞后的基础卷 statfs。保护等级不同要明示，不能将旧版“校验 0”理解为同等保护零成本。

真实应用的独立清单对比使用正确时点的使用后数据；只保留支撑结论的计数和摘要，私有文件名与原始日志不入笔记。生产身份、二进制哈希与运行记录分别证明实际构建；bundle ID 和显示版本不足以识别产物。

## Existing evidence

早期 Issue #65 的真实崩溃、AppContainer 原函数探针、静态调用树和合成系统调用矩阵证明不同问题；25 个隐藏 tmp 副本通过结构检查不证明真实应用功能。10 月 1 日严格复制的原生镜像/WAL/嵌套挂载与七阶段冷状态测试也是各自构建的证据，不是 build 30 的再次验收。归档保留 48 条 warning、UI 跳过与 Intel/旧系统运行缺口，未执行项不折算为通过。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/实施验收/implementation/2026-10-01-migration-safety-verification.md（S027），以及同归档 S002、S026、S035–S036、S057、S063、S079。

来源的固定镜像对照为 20,000 × 4 KiB 与 4 × 128 MiB，按旧、新、新、旧执行，每版每数据两轮中位数。build 27 已测速，build 28–30 未重测。真实微信 build 27 往返比对使用 38,674 文件的各自正确时间点；10 月 14 日另有多应用验证。

来源保留了容量观测、夹具、签名计时和 build 28 组合运行失败；有些独立重跑通过，有些范围仍未测。`script/isolate_test_host.py`、`script/prepare_apfs_baseline.py`、`script/benchmark_apfs_lifecycle.py`、`script/validate_private_apfs.py` 在当前工作区尚未提交，因此策略实现先记为 proposed。

## Related decisions

- 实际崩溃与系统探针区别见[企业微信复盘：保护容器骨架并保留历史还原](../../implemented/bug-fix/2026-10-01-wecom-container-integrity.md)。
- 结构资格不代表临时工作流可用，见[临时目录的结构资格与迁移推荐分开](../feature/2026-10-01-temporary-directory-migration-policy.md)。

- 真实权限事故不能由普通镜像成功掩盖，见[微信事故：检查卸载后的本地入口必须先于卸载](../bug-fix/2026-10-12-wechat-mount-recovery.md)。
- 私有 APFS 宿主隔离叠加在既有记录库与日志防线上，见[测试注入目录还必须隔离记录库和共享日志](../../implemented/testing/2026-10-01-test-state-isolation.md)。
- 可比较的性能证据用于验证该简化，见[复用复制验证结果，不用时间戳替代内容证明](../simplification/2026-10-12-apfs-verification-reuse.md)。

## Alternatives considered

- **用普通单测或镜像替代全部实机验证**：重复性好且风险低，却没有覆盖物理盘建卷、真实系统标签和 TCC 边界。
- **混合不同构建、Debug/Release 或只取最快轮次**：报告更简短，但数据不可比较，无法归因于产品改动。
- **用基础卷 statfs 证明容器回收**：调用简单，来源却观察到卷已删除而统计滞后，应按真实容器身份观测。

## Acceptance criteria

脚本与隔离入口随代码提交；相同基线可复跑且命令、fixture 身份和失败事实可追溯。模拟、镜像、实际应用、构建与平台分别报告，未执行项不算通过。没有物理断电、Intel、旧系统或真实登录竞态证据时明确留白，之后才转 implemented。

## Risks

镜像位于内部 SSD，吞吐不能外推 USB 外盘。真实业务验证需要独立授权，本篇不是操作用户应用或制造故障的许可。IINA 扩展属性来源、三个应用还原后的原入口 UI、真实魔镜修图与微信官方更新/重装退休等仍有来源已列明的缺口。
