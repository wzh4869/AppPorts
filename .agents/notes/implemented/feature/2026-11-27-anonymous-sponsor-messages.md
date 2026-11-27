# Agent Note: 文档赞助页支持匿名留言混排与数据隔离

Status: implemented

## Problem

部分微信赞赏用户未留昵称但附带了留言。根目录 `sponsors.json` 同时供在线文档站与已安装的 AppPorts 客户端读取；若把匿名赞赏直接写入 `sponsors` 数组，已安装旧版本和当前版本的应用会在「关于 AppPorts」中展示匿名条目或因缺少 `name` 解码失败，且用户明确要求匿名仅留言者不在 GitHub 与 AppPorts 内展示，仅在文档赞助页与实名赞助者混排展示。

## Decision

根目录 `sponsors.json` 保留既有 `sponsors` 数组供实名赞助者使用（允许可选 `message` 字段供网页展示），并在顶层新增独立字段 `anonymousSponsors` 存放仅留言、无昵称的赞赏记录（`message`、`amount`、`date`）。

AppPorts 客户端的 `SponsorsPayload`（`AppPorts/AboutView.swift`）只解码 `updatedAt` 与 `sponsors`，不读取 `anonymousSponsors` 与 `message`；已安装客户端与 GitHub README 均继续只展示实名赞助者，不泄露匿名留言与金额。

文档站组件 `User_docs/components/sponsors.tsx` 与便携 Markdown 导出器 `User_docs/scripts/prepare-fumadocs.mjs` 将 `sponsors` 与 `anonymousSponsors` 合并后，统一按金额从高到低、同额按 `YYYY-MM-DD` 日期从早到晚混排。网页卡片采用「左身份+留言、右金额垂直居中」的统一结构，桌面端双列网格通过 `grid-auto-rows: 1fr` 强制所有卡片等高（窄屏单列恢复 `grid-auto-rows: auto` 自适应高度）：左侧 `.sponsor-card-main` 固定上行身份（实名显示默认字重/深色昵称与可选链接，匿名显示柔和灰色的本地化标签：简中「匿名赞助者」、繁中「匿名贊助者」、英文「Anonymous」）、下行仅在存在留言时渲染无竖线边框的柔和灰字原样留言；右侧 `.sponsor-card-amount` 在整张卡片内垂直居中展示金额，避免第二行在「身份状态」与「留言内容」之间混义。

## Data contract

```json
{
  "sponsors": [
    { "name": "南极风🔒🔐（唐山锁之家）", "link": "", "amount": 1, "date": "2026-10-24", "message": "好软件" }
  ],
  "anonymousSponsors": [
    { "message": "🎂", "amount": 100, "date": "2026-11-20" }
  ]
}
```

- `sponsors[]`：必须包含 `name`、`amount`、`date`，供文档站、AppPorts 客户端与 GitHub README 同步消费；`message` 仅由文档站渲染与导出。
- `anonymousSponsors[]`：每条记录必须包含 `message`、`amount`、`date`；只由文档站前端组件与 `docs:prepare` 导出脚本消费，AppPorts 与 GitHub README 不消费此字段。
- 三语本地化词条同步：`User_docs/config/locales.json` 为 `zh-Hans`、`en`、`zh-Hant` 补齐 `匿名赞助者` 与 `留言` 键值，保证 `docs:check` 三语键集一致校验通过。

## Alternatives considered

- **在 `sponsors[]` 中增加 `anonymous` 布尔标记并在 Swift 端过滤**：可少一个顶层数组，但无法兼容已发布的旧版 AppPorts 客户端，旧版会忽略布尔标记直接把匿名条目渲染进「关于 AppPorts」，甚至因 `name` 缺失导致整份列表解码失败。
- **拆分为独立的 `anonymous-sponsors.json` 文件**：物理隔离更彻底，但会拆散同一批赞赏记录的单一数据源，且需要额外调整静态资产复制与 `docs:check` 校验契约。
- **匿名卡片主行放留言、次行放「匿名赞助者」（原方案 B）或单行紧凑拼接（原方案 C）**：初版实测在浏览器中与实名留言卡片混排时，出现两张结构相同但上下行语义相反的卡片（第二行一会儿表示「匿名身份」，一会儿表示「实名留言」），导致扫读混乱，因此改为统一「上身份、下留言」结构。

## Consequences

- **收益**：向后兼容所有已安装 AppPorts 版本；实名与匿名赞助数据留在同一份 `sponsors.json` 内按同一金额/时间规则混排；文档站静态 HTML 与 `/docs-md/<locale>/sponsor.md` 同步覆盖实名留言和匿名条目。
- **代价**：`sponsors.json` 的静态导出 Markdown 表格由 2 列扩展为 3 列（赞助者 / 留言 / 金额）；后续新增匿名赞赏需写入 `anonymousSponsors` 而非 `sponsors`。
- **已知边界**：`README.md` 与 `README_CN.md` 仍需人工或同步脚本与 `sponsors` 实名列表保持一致，不自动同步 `anonymousSponsors`。

## Verification

以实际执行的 `docs:build`、`docs:typecheck`、`docs:check`、Agent Note 三项门禁、`SponsorsTests` 单元测试及 Release `xcodebuild clean build` 结果为准。
