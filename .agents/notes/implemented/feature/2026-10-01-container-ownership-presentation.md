# Agent Note: 容器归属、个人目录链接与大小显示

Status: implemented

> 迁移自 worktree migration-safety / docs/plans/2026-10-01-migration-safety.md
> 迁移自 worktree migration-safety / docs/reports/2026-10-01-directory-ui-followup.md
> 迁移自 worktree migration-safety / docs/reports/2026-10-01-container-ownership-ui.md

## Problem

容器中的 Desktop、Downloads 等链接指向用户个人目录，并非应用独占数据；把名称候选和所有父子大小混成归属与可释放空间，会误导迁移选择。先重建祖先再隐藏还可能把应消失的结构重新带回界面。

## Decision

普通 Containers 以真实应用 bundle ID 对应的直接子目录确定发现范围，不用产品名、子串或任意嵌套目录证明所有权。历史受管与恢复记录独立发现。Group Containers 仍使用既有候选匹配，不能声称已由 entitlement 验证共享组归属。

精确层级、名称和目标都吻合的个人目录链接不计入应用大小、不遍历目标、不给迁移或还原能力；普通个人入口无论两个显示开关怎样组合都隐藏。受管、冲突、不可读和恢复项仍可见，不可被误判为可忽略快捷方式。

各行保留父容器路径上下文，大小注明本卷或目标范围；本卷统计不跨子挂载或子软链，父目录不等于各子行相加，逻辑大小不等于物理占用。先过滤不可见节点，再重建最近可见祖先和搜索结果；锁定结构开关只控制展示。

隐藏目录未被枚举不等于被策略禁止；发现范围、总占用、可迁移候选和可释放大小各有含义。临时目录可能含硬链、软链或以后新建的随机兄弟项，不能把一次扫描的总字节直接承诺为可回收量。共享临时区无法可靠按应用归属时不强行分摊。

详情面板保存用户拖动得到的高度，默认值与有限数值检查独立于小窗口临时 clamp；布局压缩不覆盖用户保存值，恢复较大窗口仍沿用其选择。这是呈现状态约束，不另立纯样式决定。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/T/调查报告.md（S065），以及同归档 S011、S030、S038。

## Related decisions

- 名称候选发现的两层访问限制与取消检查见[应用数据发现限制层级并响应取消](../bug-fix/2026-10-26-应用数据发现限制层级并响应取消.md)，不改变本篇普通容器的精确身份范围。

- 状态统计与精确可见行的交集见[状态统计切换为精确目录筛选](2026-10-01-directory-status-filtering.md)。
- 隐藏临时数据的推荐边界见[临时目录的结构资格与迁移推荐分开](../../proposed/feature/2026-10-01-temporary-directory-migration-policy.md)。

- 容器发现依赖真实应用身份，见[应用数据扫描使用真实应用身份](../bug-fix/2026-09-29-app-data-identity.md)。
- 目录开关与归属呈现不绕过执行层，见[目录显示、执行权限与严格数据复制分开约束](../architecture/2026-10-01-data-path-copy-safety.md)。
- 统一向导若采用本呈现规则仍须保留归属限制，见[统一应用级迁移与修复引导](../../proposed/feature/2026-09-26-unified-migration-guidance.md)。

## Alternatives considered

- **按产品名和子串发现普通容器**：能找到部分 helper、扩展或别名，但无法证明归属，也可能关联无关应用。
- **结构开关开启时展示个人快捷入口**：可以解释容器布局，早期界面已采用；后续选择始终隐藏普通入口，保留异常/恢复例外，避免把个人数据呈现成应用候选。
- **完整建树后补回所有上下文祖先**：层次容易理解，却会把应隐藏节点重新显示；使用最近可见祖先及路径副标题保留语境。

## Consequences

发现与统计的含义更清楚，个人目录不会被误计为应用独占数据。代价是未验证的 helper、扩展和别名容器可能不被名称搜索发现；共享组和其他 Library 启发式仍有局限。显示更多结构不能改变微信白名单或低层操作能力。

## Verification

可核对 `AppPorts/Utils/DataDirScanner.swift`、`AppPorts/Models/DataDirItem.swift` 和 `AppPortsTests/DataDirPresentationTests.swift`、`AppPortsTests/DataDirTreeTests.swift`、`AppPortsTests/DataDirScannerTests.swift`。来源最终所有权显示报告优先于较早的个人入口展示方案，合成夹具和组件渲染通过不代表操作过真实用户容器。
