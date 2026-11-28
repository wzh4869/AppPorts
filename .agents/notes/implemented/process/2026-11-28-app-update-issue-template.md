# Agent Note: 新增外盘应用更新兼容与异常反馈 Issue 模板

Status: implemented

## Problem

用户在迁移应用到外盘后，经常需要申请 AppPorts 兼容某款应用的自更新，或反馈已被识别为「更新：可用」的应用实际无法更新。此前这些反馈只能混在通用问题反馈或功能建议里，缺少应用更新状态、应用更新守护开关、更新方式及诊断包引导等针对性字段。

## Decision

在 `.github/ISSUE_TEMPLATE/` 新增独立的双语表单模板 [app-update.yml](../../../.github/ISSUE_TEMPLATE/app-update.yml)，使用专用标签 `["app-update"]` 与标题前缀 `[UPDATE] `，分别覆盖“申请兼容外盘自更新”与“显示可用但实际更新失败”两类场景。模板要求填写反馈类型、目标应用名称与版本、AppPorts 当前显示的更新状态与守护开关状态、具体现象，以及 AppPorts 与 macOS 版本；应用来源/Bundle ID、文件系统、截图、环境补充与诊断日志包为选填，并在诊断包说明中强烈推荐提交，同时提供发送至 `a@shimoko.com` 并注明 Issue 链接/编号与对应应用信息的指引。

同步更新 [bug.yml](../../../.github/ISSUE_TEMPLATE/bug.yml) 的 `app_version` 下拉选项（顶部补充 `2.4.1` 与 `2.4.0`），并将 [bug.yml](../../../.github/ISSUE_TEMPLATE/bug.yml) 与本模板的诊断包指引统一改为「设置（⚙️）→ 日志设置 → 导出诊断包」及“强烈推荐”提示；同时将 `.github/ISSUE_TEMPLATE/` 下各表单的中英文 `description` 与说明段落改为通过空行分段，避免 GitHub 渲染将单次换行折叠为同一段。

## Existing-note audit

检索 `.agents/notes/` 中关于反馈流程与 Issue 模板的活跃记录，命中 [bug-report-form](2026-10-24-bug-report-form.md)。两篇面向不同反馈入口、各自有效，本文通过相对链接关联，不修改或归档原笔记的既有结论。

## Alternatives considered

- 在 `bug.yml` 与 `feature.yml` 中分别增加子选项：不新增入口，但难以同时承接“兼容申请”和“已支持应用更新失败”两类问题，且会加重通用表单长度；独立模板更直观且便于按 `app-update` 标签分流。
- 将诊断日志包设为强制必填（`required: true`）：能保证每条更新故障都有日志，但纯申请新应用兼容或暂时无法导出日志的用户会被直接拦截；保留非强制校验并在标题与正文强烈推荐提交或邮件备注发送。

## Consequences

- GitHub 新建 Issue 弹窗会新增专属入口，反馈内容结构更贴合 `AppUpdateRoute`、更新徽章与更新守护排查需求；专用标签 `app-update` 需在 GitHub 仓库 Labels 中存在才能自动挂载，否则 GitHub 会忽略该标签但不影响创建 Issue。
- 本次同步补全了 `bug.yml` 的 `2.4.0` 与 `2.4.1` 版本选项，后续版本发布仍需人工同步模板列表。
