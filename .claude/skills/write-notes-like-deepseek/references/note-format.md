# 按需阅读：Note 文件格式

> SKILL §2 的展开。写/改 Note 时对照；只改代码不动 Note 时跳过。

## 头块（前三行，检查脚本会核对）

```markdown
# Agent Note: <标题>

Status: <状态>
```

- `proposed` → `Status: proposed`
- `implemented` → `Status: implemented`
- `rejected` → `Status: rejected — <一句话原因>`

标题前必须带 `Agent Note: ` 前缀；状态不含日期与括号；必须与所在 lifecycle 文件夹一致（脚本会交叉核对）。文件名日期是首次提出日，git 承载其余时间信息。

## Body 骨架

每篇 Note 都以 `## Problem` 开头——动机要能脱离方案独立成立。之后按 lifecycle区分：

**`proposed/`**

```markdown
## Problem
## Proposal
…自由节…
## Alternatives considered
## Acceptance criteria
## Risks
```

`Proposal` 可用将来时；`Acceptance criteria` 说清什么可观察状态算完成；`Risks` 同时写风险与已知取舍。

**`implemented/`**

```markdown
## Problem
## Decision
…自由节…
## Alternatives considered
## Consequences
```

`Decision` 用现在时描述已落地事实；门禁只拒提案标题（`## Proposal` / `## Plan` / `## Migration plan` / `## Acceptance criteria` 及其中文别名）；用 `## Consequences` 同时记录代价与收益；可按需加 `## Testing` / `## Verification` 等现在时事实节。现在时靠人写，不靠词法扫描。

**`rejected/`**

冻结的 proposal 形态，verdict 在 `Status:` 行；保留提案时的 `Alternatives` 等节，不改写为对立面。

## Alternatives considered（必写）

每篇 Note 必含 `## Alternatives considered`：每个**真考虑过**的备选为何没选，一段一备选（可用 `### Why not <X>?` 子节）。没有过的选项不要编。「不做 / 复用现状」仅当当时真的权衡过才写。脚本只检查这一节在不在。

## 时态与禁止改写

- `proposed` 可用将来时；`implemented` 一律现在时，描述已落地事实。
- 一条 Note 永远不被改写成另一个决定；被取代用新 Note 接管，旧 Note 按归档/合并规则处理。

头块标题兼容全角冒号（`# Agent Note：标题`，中文输入法常打出全角）；新笔记建议半角。

## 自由节与文风

- 自由节（package 拓扑、wire 契约、schema 等）放在 `Decision` 与 `Alternatives` 之间。
- 保留可检索的机制名与 `must`/`may`/`never` 时序强调；一个事实只在一处讲透，其余链过去。
- 跨 Note 引用用相对 Markdown 链接 `[topic](../../implemented/architecture/2026-…-….md)`，不要裸数字。

格式与别名表对齐 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 notes 规范；本项目为中文单语，头块 `Agent Note:` 与 `Status:` 保持英文原文以便脚本核对，正文用中文。
