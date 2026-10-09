# GitBook 文档迁移

迁移目标是现有 [AppPorts Docs](https://app.gitbook.com/o/EVCRCIIkGN9ucEMGTbom/sites/site_02JAH)。站点 Git Sync 已连接 `wzh4869/AppPorts` 的 `main` 分支，Project directory 为 `./User_docs`；`gitbook-docs.yaml` 将八种语言映射到 `gitbook/` 下各目录。

2026 年 10 月 9 日已完成初次导入：8 个 Space 全部同步成功，259 个页面的 Git blob 与迁移文件逐一一致。`space-ids.json` 保存此次导入返回的真实页面地址，迁移文件中的 90 处跨语言引用据此解析；`anchor-ids.json` 保存被引用标题的实际渲染 ID，用于修正 43 处段落链接。

## 内容和导航

保留原有 219 篇正文：简体中文 32 篇、英文 31 篇，繁体中文、日文、韩文、德文、法文、西班牙文各 26 篇。40 个新增目录页承接 VitePress 的原有折叠分组，目录名称与顺序来自 `docs/.vitepress/config.mts`。原来指向其他语言的实验记录和隐私政策继续使用对应语言的现有内容。

- 每种语言的 `README.md` 保留原首页标题、标语、操作入口和三项功能说明，并采用 GitBook 原生导航卡片。
- VitePress 提示块转换为 GitBook hints，折叠块转换为 details；代码块与 Mermaid 源码保留。
- 隐私政策、开源许可和赞助名单从现有 Vue 组件数据展开。赞助名单保留仓库根 `sponsors.json` 的排序和金额格式。
- 自定义标题锚点转换为 GitBook 的 `<a href="#id" id="id"></a>` 形式，64 个显式 ASCII 锚点保持不变。GitBook 会规范化非 ASCII 标题 ID，并为重复结果添加序号；指向这些标题的段落链接使用导入后实际的 `heading.meta.id`。
- 每个 Space 的 `.gitbook.yaml` 将旧 `.html` 路径重定向到对应 Markdown 页面。

## 本地维护

```sh
cd User_docs
npm ci
npm run docs:gitbook:check
```

转换工具 `scripts/migrate-gitbook.mjs` 使用当前 VitePress 工程的解析器和依赖。默认导出只新增缺失文件，保留已经存在的页面，避免覆盖 GitBook 或人工修改。

### GitBook 原生排版

GitBook 版式由 `scripts/gitbook-design.mjs` 统一定义，参考 [Cherry Studio 文档](https://docs.cherryai.com.cn/) 的品牌色顶栏、页面图标和清楚的阅读层次，使用 AppPorts 的蓝紫色品牌方案。

- 八语首页采用紧凑介绍、操作按钮、实用导航卡和功能卡；卡片可整块点击，功能说明保持原意。
- 40 个主题目录采用带图标和简介的导航卡；首页与目录使用宽版并隐藏右侧提纲、分页和更新信息。
- 正文使用正常阅读宽度，统一页面图标；主要指南补充本地化简介，长文保留右侧提纲。
- 八语快速开始使用 GitBook `stepper` 展示下载、安装和授权三个步骤；App Store 授权说明、图片和警告继续直接显示。
- 页面路径、`SUMMARY.md` 层级、标题锚点、代码示例和 Mermaid 不随排版调整改变。

导出器会对新生成页面应用这些模板，仍不会覆盖已存在的编辑内容。调整模板后，应先导出到新的临时目录、解析链接并检查差异，再合入需要更新的页面。校验同时检查 frontmatter、GitBook 块配对、卡片和正文链接目标，以及迁移时保留的代码块和锚点。

站点的配色、侧栏、标志和顶栏链接记录在 `gitbook/site-theme.json`，由 GitBook 站点设置管理。Git Sync 不会自动应用此文件；调整时通过 CLI 读取现有设置并合并这些设计字段，再提交完整设置，保留其他站点选项。标志复用已导入的 AppPorts 图片，浅色和深色模式分别使用蓝紫色与较亮的紫色。

需要重新比较源文档或更新赞助名单时，导出到新的目录，再审阅和合并需要的变化：

```sh
node scripts/migrate-gitbook.mjs export --output /tmp/appports-gitbook-review
```

`gitbook/migration-manifest.json` 记录原文件到迁移文件的映射。初次同步创建语言 Space 后，通过 GitBook CLI 获取各 Space 的页面树，将真实 Space ID 与 `page.git.path` / `page.path` 对应关系写入 `gitbook/space-ids.json`。对段落链接涉及的页面，读取 `spaces content page get <spaceId> <pageId> --format document --json`，按标题的文字、层级和顺序将原 ID 与 `heading.meta.id` 对齐，写入 `gitbook/anchor-ids.json`。不能使用 `heading.data.id` 代替：日文、韩文标题规范化后可能重名，只有 `meta.id` 包含实际渲染的去重序号。随后执行：

```sh
node scripts/migrate-gitbook.mjs resolve-links
npm run docs:gitbook:check
```

跨语言链接必须使用导入后的真实 `page.path`。GitBook 的发布地址受导航层级影响，不能直接从文件名猜测。校验会拒绝未解析的跨 Space 占位符与不匹配实际标题 ID 的片段；解析过程保留代码块、行内代码和标题定义。

预览已核对中英文首页与语言切换、快速开始图片与提示块、Mermaid、隐私政策、开源许可、赞助名单，以及中英文旧 `.html` 地址的重定向。Mermaid 在滚动到图表后延迟加载；未发布站点的预览需有效的临时授权，可用 CLI 的站点 publishing preview get 重新打开预览。

Git Sync 双向同步 `gitbook/` 中的内容；VitePress 的 `docs/` 保留为现有网站的源文件。两份正文不会自动互相转换。开始在 GitBook 编辑后，以 `gitbook/` 作为新站点内容源，避免运行批量覆盖。

## 发布与旧域名

内容迁移使用现有站点和套餐。迁移不修改 DNS，也不停止 VitePress 部署。

旧客户端仍会请求 `https://docs-appports.shimoko.com/sponsors.json`，也会打开该域名下的 `.html` 文档和锚点。原域名的 JSON 响应必须保持可用；若以后把旧域名切换到 GitBook，需先为 `/sponsors.json` 保留转发，并验证旧页面重定向。`docs/public/latest.json` 也继续随原部署保留。

发布前应检查 GitBook 预览的首页、挂载迁移、隐私政策、许可、赞助、语言切换、图片、Mermaid 与旧地址跳转。最终域名和托管方式改变时，隐私政策中有关站点及统计服务的描述应据实际部署复核。
