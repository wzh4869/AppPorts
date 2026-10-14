# 按需阅读：校验脚本

> SKILL §6 的展开。接入 CI 时对照；本地轻量使用时跳过。

## 检查脚本（均为 tsx，零新增依赖，均可 `npx tsx` 独立运行）

1. **`verify-agent-note-tree`**（`scripts/agent-note-tree.ts` + `scripts/verify-agent-note-tree.ts`）
   - 校验 lifecycle 封闭集 `proposed/implemented/rejected` + `archived`、class 封闭集 6 个、路径深度 `{lifecycle}/{class}/file.md`、文件名 `yyyy-mm-dd-topic.md`、禁止 `INDEX.md`、活跃笔记内部相对 Markdown 链接有效性。

2. **`verify-agent-note-format`**（`scripts/verify-agent-note-format.ts`）
   - 头部：第 1 行 `# Agent Note:` 标题（半角/全角冒号都收，中文输入法常打出全角）、第 2/4 行空行、第 3 行 `Status:` 与 lifecycle 一致且全篇唯一。
   - 骨架：首节必须 `## Problem`/`## 问题`；per-lifecycle 必需节匹配中英别名（`## Decision`/`## 决策`、`## Consequences`/`## 后果` 等；`## Decision（说明）` 这类括号后缀会先剥掉再匹配）；`implemented` 禁用提案式标题（`## Proposal`/`## Plan`/`## Migration plan`/`## Acceptance criteria` 及其中文别名）。现在时是散文纪律，不扫正文。
   - 备选方案：`## Alternatives considered` / `## 备选方案` / `## 已考虑的替代方案` 等别名必写。脚本不检查「不做/复用」档，也不接受占位注释豁免。
   - 兼容：CRLF/BOM 自动归一。

3. **`verify-archived`**（`scripts/verify-archived-agent-notes.ts`，标配）
   - 每篇归档：头部布局逐行校验（L3 `Status: implemented` / L4 `Archived: YYYY-MM-DD` 紧邻 / L5 空行）。不承认 `Superseded-by:` 字段。
   - `archived/manifest.json`：每个文件有封印条目、每条目有对应文件、sha256 与磁盘内容一致（冻结 = 不可篡改的机械含义）。
   - append-only：有 git 时与基线 ref 的 manifest 逐条对比（env `AGENT_NOTE_ARCHIVE_BASE_REF`，本地默认 HEAD）。CI 必须指向变更前的 commit（本仓库 workflow：PR 用 `pull_request.base.sha`，push 用 `github.event.before`），用 HEAD 等于没查。已封印条目被改/删即报错；**无 git 自动降级**为哈希自校验并打印提示——不用 git 一样能跑，只是少了版本基线对照。
   - `--write`：先证明既有封印未变，再为未封印文件追加封印（历史语料补齐用这个）。

4. **`check-note-anchors`**（`scripts/check-note-anchors.ts`，软报告，退出码恒 0，**不进 CI**）
   - 扫描源码（env `AGENT_NOTE_CODE_ROOT` 指定根，默认 cwd；自动跳过 node_modules/.git/dist 等）里的 `// Note:` / `# Note:` 物理锚点：报告悬空锚点、没有锚点指向的 implemented 笔记、缺路径的锚点行。宿主没用锚点就不必跑。

## 接入建议

- 轻量（个人/无 git）：前两个脚本即可，归档封印在第一次归档后自然生效。
- 完整（团队）：`npm run verify-notes` 三线串进 CI，失败即红（本 Skill 的 `templates/verify-notes.yml` 可作模板，复制到宿主根目录 `.github/workflows/` 并核对脚本路径后启用）。

三个校验脚本方法上来自 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)，按通用中文单语宿主裁过：无双语三件套、无 DSH 迁仓豁免。锚点体检是可选软报告，不是 DSH 门禁。

## 脚本路径

本文的 `scripts/` 相对于 Skill 安装目录。运行命令时保持当前目录为宿主项目根目录，并使用实际 Skill 路径调用脚本；安装本身不会创建宿主 npm scripts。
