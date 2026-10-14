# 按需阅读：Class 分类

> SKILL §1 的展开。新建 Note 选 class 时对照。

## 封闭集（6 个，再加要改检查脚本）

| Class | 覆盖范围 |
|---|---|
| `feature` | 新增面向用户或模型的能力 |
| `bug-fix` | 修缺陷或补 postmortem 暴露的缺口 |
| `simplification` | 不新增能力的前提下删代码/行为/表面 |
| `architecture` | 已发布源码的结构性决定——包如何关联、运行时词汇是什么 |
| `process` | 代码之外的工具/策略/流程——门禁、包管理、vendoring 等 |
| `testing` | 测试 infra 与策略 |

判定技巧：

- `architecture` vs `process`：前者是"发出去的源码长什么样"，后者是"围绕源码的工具链与工作流"。
- `refactor` 不单列——用 `simplification` 的判据"可观察行为变了吗"区分；行为不变即 simplification，行为变了归对应 feature/bug-fix/architecture。
- `feature` 不只在"新增能力"时用——**用户/模型可见、不显然的行为或产品选择，changes 够不上架构，也归 `feature`**。判据是"行为是否可被用户或下游观察"，而不是"改动了多少代码"。只有局部实现细节、普通重构、行为不变的依赖补丁才不写任何 Note。
- 拿不准时看这条 Note 以后会被谁检索：找能力演进看 `feature`，找结构决策看 `architecture`，找门禁/发布看 `process`。

每条 Note 必带的语义要求（检查脚本管不了的）：

- **Alternatives 只记录真实考虑过的对手方案**：先写它最强的论据再否——只写弱处的拒绝是稻草人。「不做/复用」仅当当时真的权衡过才写，不要编。
- **简化必写代价上限**：`simplification` 的 `## Consequences` 要写明"这个取舍的已知上限是什么、什么信号发生时该重访"。没有升级触发条件的简化会悄悄变永久。
- **验证要可确认**：写"改对了"时落到可被检查的表面（记"哪条路径、什么量级、跑什么命令确认"），没有基线就不要用相对量词——"提升了/更快了"在没有对比基线时是未验证断言，比不写更糟。

## 检查脚本

`scripts/agent-note-tree.ts` 定义 `AGENT_NOTE_CLASSES` 常量；未知 class 文件夹、lifecycle 根下的散落 `.md` 都会报错。新增 class 必须同时改常量和本文档，否则检查直接红。

分类封闭集与判据对齐 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 notes 分类实践。
