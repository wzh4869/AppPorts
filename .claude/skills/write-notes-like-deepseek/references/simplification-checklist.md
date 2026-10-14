# 按需阅读：简化机会自检

> 提炼自 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 `dsh-find-simplifications` skill。收尾或重构时扫一遍；别在功能改动里硬塞无关简化。

## 值得删/合/降级的信号

- 公开方法、事件、配置项、包、持久化事件或测试产物没有生产消费方（测试/文档是唯一消费方且行为非关键）。
- 两处表示同一事实（尤其是持久化事件与瞬态事件各存一份）。
- 某个能力的所有实现都必须实现某方法，但没有消费方在用它。
- 包只为测试/demo/支撑而存在，增加发布与依赖成本。
- 为“以后可能要”做的通用性：多会话、后台任务台账、年中转向、工具自带 UI 等，无当前归属。
- 为不存在的 API 准备的不变式、回滚、快照或特判。
- 手写了业界已有包或同版本 Node 已提供的能力，换掉能净删除实现与对应测试。

## 怎么证实

- 用 `rg` 搜符号/事件/配置键/包名，看生产代码（`packages/*/src`、`examples` 运行时、`loader/config` 路径）是否真在用。
- 区分生产/非生产/模糊语料——测试与文档里的出现不算生产证据；`knip` 可辅助但不能替代读调用点。
- 小而确定的清理用 `TODO/FIXME/XXX` 记下，别为此开一条 Note；只有 durable 的取舍才值得一条 proposed Note。
- Hand-rolled vs 依赖：看净删除（实现+测试+文档）、健康度、边界贴合度；能真删才换，包一层同样复杂度不算赢。

## 与 Notes 的衔接

- 符合信号且这个取舍需要留下来 → 写 `proposed/simplification` Note（Problem/Proposal/Alternatives/Acceptance/Risks）。
- 已落地的 simplification → `implemented/simplification`，Consequences 同时写删掉的成本与省下的负担。
- 触发 Note 树膨胀时，用 `archiving.md` 的“未来参考价值”判定是否归档，而非字数/年龄。
