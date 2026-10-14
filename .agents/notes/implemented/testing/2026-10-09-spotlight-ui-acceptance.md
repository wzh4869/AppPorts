# Agent Note: Spotlight 去重必须验收真实搜索与原入口

Status: implemented

> 迁移自 docs/issue-67-validation.md

## Problem

索引查询、文件存在和界面组件渲染只能证明各自表面，不能证明真实 Spotlight 窗口已经去重，也不能证明用户删除的入口不会被后台刷新重新建立。

## Decision

搜索修复的验收区分索引、真实搜索窗口、入口身份和启动行为。发布去重结论前，要在目标系统的实际 Spotlight 中搜索，并验证 Dock、文档打开、URL Scheme、离线、更新和重连后的行为。

用户删除或移入废纸篓的入口不得被普通刷新自动补回；显式重新链接才是重建动作。同名磁盘/应用、未知身份和临时不可读不能触发自动重关联或删除。还原成功而外盘清理未完成时，残留副本与其他应用依赖的排除规则仍需分别处理。

当前源码的 `AppPorts.noindex` 库方案决定实现路径。本篇保留验收约束，不把源文件中的手动系统隐私设置步骤当作现行产品流程，也不把旧面板的用户确认当作持续自动验证。

## Related decisions

- 旧扫描不可覆盖新结果的列表机制相关，见[应用列表即时发布与手动大小重测](../bug-fix/2026-09-30-app-list-refresh.md)。

## Alternatives considered

- **用 mdfind 和单测代替实机 UI**：可重复且容易自动化，却不能证明系统搜索窗口展示与启动目标。
- **只按同名或入口缺失自动修复**：可以减少用户步骤，但会恢复用户明确删除的入口或关联错误副本。

## Consequences

验收结果能准确区分已证明与未证明的用户行为。代价是需要多个 macOS 版本及真实界面环境；无法完成时不能将去重部分作为已解决发布。来源原文未记录从手动隐私配置转向 noindex 的全部取舍，本篇不补造。

## Verification

来源明确要求 macOS 26、27 实际搜索；其 macOS 27 UI 自动化启动失败、macOS 26 环境缺失，相关验收未完成。当前实现可从 `AppPorts/Services/AppSearchExclusionService.swift`、`AppPortsTests/AppSearchExclusionTests.swift` 和 `AppPortsTests/AppSearchRecordTests.swift` 核对；笔记迁移不等于补齐实机验收。

首次提出日原文未记录；经迁移确认，文件日期采用最早可核实的相关提交 `e950e6d` 的 2026-10-09，不将提交日冒充已知的提出日。
