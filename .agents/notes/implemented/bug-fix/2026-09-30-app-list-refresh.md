# Agent Note: 应用列表即时发布与手动大小重测

Status: implemented

> 迁移自 docs/superpowers/specs/2026-09-30-app-list-refresh-design.md
> 迁移自 docs/validation/app-list-refresh.md

## Problem

扫描会等待磁盘与签名探测，缺少进度时刷新看似无效。只比较应用根目录 mtime 的大小缓存，无法发现包内文件的原地增长；成功迁移若等待全量扫描才更新列表，也会继续显示过时位置。

## Decision

两侧列表分别用 `AppListScanState` 管理请求身份、进度和待重测需求。手动刷新强制重新测量大小；自动扫描复用有效缓存。自动请求接替手动请求时继承尚未完成的重测要求，旧请求不能发布结果或结束新请求。元数据不可读不构成缓存命中，本地入口大小与真实内容大小不混用。

迁出、链接和还原成功后依据服务返回的实际源/目标更新两侧列表，保留身份与签名信息，同时失效旧扫描。操作完成协调一次后台扫描；失败项不发布成功。还原已生效而外部清理失败时保留外部副本行，不能因本地已可用就假装旧副本消失。

## Related decisions

- 即时发布反映服务实际提交结果，持久化完成依据见[迁移以持久化切换和可重试清理为完成依据](../architecture/2026-10-10-verified-transfer-lifecycle.md)。
- 搜索实际展示与原入口验收不能由列表刷新测试代替，见[Spotlight 去重必须验收真实搜索与原入口](../testing/2026-10-09-spotlight-ui-acceptance.md)。

## Alternatives considered

- **始终复用根目录 mtime 缓存**：减少枚举，但来源已复现包内从 1,024 增至 8,192 字节而根目录时间不变。
- **每次自动扫描也全量重测**：可减少缓存陈旧，却增加常规监控的磁盘读取；明确的手动刷新承担强制重测。
- **操作后只等待完整扫描**：状态更新路径统一，却把已知的成功结果绑定到不相关的签名与大小等待。

## Consequences

用户能观察刷新进度，并立即看到已完成的位置切换。手动测量仍可能较慢，原有签名超时也可能发生；进度反馈不构成性能提升承诺。请求接替与旧版套件的部分清理结果需要额外状态回归。

## Verification

`e19e409` 保留已实现行为。可检查 `AppPorts/Models/AppListScanState.swift`、`AppPortsTests/AppListRefreshTests.swift` 和 `AppPortsTests/AppListTransferTests.swift`。2026-09-30 来源记录最终 670 次执行通过，也保留了中间 codesign 超时；本次迁移没有重跑这些测试。
