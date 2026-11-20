# Agent Note: 恢复文档站 Umami 页面统计

Status: implemented

## Problem

旧 VitePress 站的 Umami 接入随配置删除，Fumadocs 导出页没有加载统计脚本。文档站仍可阅读，但常规页面访问不再上报到已有的 Umami 站点。

## Decision

三语共用的 `SiteDocument` 使用 `next/script` 在页面可以交互后加载 Umami Cloud 脚本，沿用后台对应 `docs-appports.shimoko.com` 的原站点 ID。用 Umami 自带的 History API 监听记录站内路由变化。上报仅限正式文档域名，页面地址去掉查询参数与章节锚点。根目录和文档站三语隐私政策同步说明接入范围。

[三语文档站替代旧站](../architecture/2026-10-15-three-language-docs-replacement.md)确定了共享布局与静态部署方式，本次在共享布局补回统计。检索活跃笔记未找到其他 Umami 接入决策。

## Alternatives considered

- 在 EdgeOne 注入脚本可以直接覆盖正式域名，但会把统计配置与静态产物、隐私政策分开维护。
- 在每个路由或语言布局里手动上报可以逐页控制触发时机，但各入口需要一起维护，且会与追踪脚本自动记录站内跳转的行为重叠。

## Consequences

上线后的新访问写入原站点的统计。断档期间未发送的事件无法通过这次接入补齐。脚本和上报服务由 Umami Cloud 提供，网络或内容拦截仍可能使个别访问无法计数。
