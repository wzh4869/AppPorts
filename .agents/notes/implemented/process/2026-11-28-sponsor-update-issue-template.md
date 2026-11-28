# Agent Note: 新增赞助者信息修改 Issue 模板

Status: implemented

## Problem

已赞助用户需要修改名单中的赞助名字、赞助备注留言、个人链接，或在实名展示与匿名展示之间切换时，缺少专属的 GitHub 反馈入口，也缺少在「匿名改为实名」场景下核对精确到小时付款时间的明确要求。

## Decision

在 `.github/ISSUE_TEMPLATE/` 新增双语表单模板 [04-sponsor.yml](../../../.github/ISSUE_TEMPLATE/04-sponsor.yml)，使用专用标签 `["sponsor"]` 与标题前缀 `[SPONSOR] `。表单支持多选修改类型（修改赞助名字、修改备注留言、修改个人链接、实名改为匿名、匿名改为实名），并在顶部引导优先通过邮件联系 `a@shimoko.com` 以避免在公开 Issue 暴露原昵称、付款时间或赞赏截图关联信息。针对「匿名改为实名」场景，在说明与必填字段中明确要求提供至少精确到小时的付款时间及金额/原备注用于核对；针对「实名改为匿名」，引导区分“仅隐藏名字保留备注匿名展示”与“完全撤下”，与 [sponsors.json](../../../sponsors.json) 的数据结构保持一致。

## Existing-note audit

检索 `.agents/notes/` 中关于赞助名单与 Issue 模板的活跃笔记，命中 [anonymous-sponsor-messages](../feature/2026-11-27-anonymous-sponsor-messages.md)、[bug-report-form](2026-10-24-bug-report-form.md) 与 [app-update-issue-template](2026-11-28-app-update-issue-template.md)。前一篇定义 `sponsors.json` 实名与匿名分离的数据模型，后两篇覆盖不同反馈类型模板，均各自有效且无冲突，不修改或归档。

## Alternatives considered

- 在 `config.yml` 中使用 `mailto:a@shimoko.com` 外链：不创建公开 Issue，但 GitHub `config.yml` `contact_links` 仅可靠支持 `http://` / `https://` 网页 URL，`mailto:` 存在被校验拒绝或跳转失效的风险；改为独立 Issue 表单并在顶部强烈建议优先发邮件。
- 仅在文档站 `sponsor.md` 保留文字邮箱提示、不加 Issue 入口：网页与 GitHub Issue 弹窗割裂，用户在仓库内点击 New Issue 时看不到对应入口。

## Consequences

- GitHub 新建 Issue 弹窗会增加赞助者信息修改入口，既明确建议邮件私信 `a@shimoko.com`，也为愿意直接填表的用户保留通道；同样需在 GitHub 仓库 Labels 中创建 `sponsor` 标签以使自动贴标生效。
- 匿名改实名与实名改匿名仍在收到邮件或 Issue 后由维护者手工核对并更新 [sponsors.json](../../../sponsors.json)。
