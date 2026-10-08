# GitBook 文档迁移

迁移目标是现有 [AppPorts Docs](https://app.gitbook.com/o/EVCRCIIkGN9ucEMGTbom/sites/site_02JAH)。站点 Git Sync 已连接 `wzh4869/AppPorts` 的 `main` 分支，Project directory 为 `./User_docs`；`gitbook-docs.yaml` 将八种语言映射到 `gitbook/` 下各目录。

## 内容和导航

保留原有 219 篇正文：简体中文 32 篇、英文 31 篇，繁体中文、日文、韩文、德文、法文、西班牙文各 26 篇。40 个新增目录页承接 VitePress 的原有折叠分组，目录名称与顺序来自 `docs/.vitepress/config.mts`。原来指向其他语言的实验记录和隐私政策继续使用对应语言的现有内容。

- 每种语言的 `README.md` 保留原首页标题、标语、操作入口、Logo 和三项功能说明。
- VitePress 提示块转换为 GitBook hints，折叠块转换为 details；代码块与 Mermaid 源码保留。
- 隐私政策、开源许可和赞助名单从现有 Vue 组件数据展开。赞助名单保留仓库根 `sponsors.json` 的排序和金额格式。
- 自定义标题锚点转换为 GitBook 的 `<a href="#id" id="id"></a>` 形式。普通标题也保留原 VitePress 锚点。
- 每个 Space 的 `.gitbook.yaml` 将旧 `.html` 路径重定向到对应 Markdown 页面。

## 本地维护

```sh
cd User_docs
npm ci
npm run docs:gitbook:check
```

转换工具 `scripts/migrate-gitbook.mjs` 使用当前 VitePress 工程的解析器和依赖。默认导出只新增缺失文件，保留已经存在的页面，避免覆盖 GitBook 或人工修改。

需要重新比较源文档或更新赞助名单时，导出到新的目录，再审阅和合并需要的变化：

```sh
node scripts/migrate-gitbook.mjs export --output /tmp/appports-gitbook-review
```

`gitbook/migration-manifest.json` 记录原文件到迁移文件的映射。初次同步创建语言 Space 后，通过 GitBook CLI 获取各 Space 的页面树，将真实 Space ID 与 `page.git.path` / `page.path` 对应关系写入 `gitbook/space-ids.json`，再执行：

```sh
node scripts/migrate-gitbook.mjs resolve-links
npm run docs:gitbook:check
```

跨语言链接必须使用导入后的真实 `page.path`。GitBook 的发布地址受导航层级影响，不能直接从文件名猜测。

Git Sync 双向同步 `gitbook/` 中的内容；VitePress 的 `docs/` 保留为现有网站的源文件。两份正文不会自动互相转换。开始在 GitBook 编辑后，以 `gitbook/` 作为新站点内容源，避免运行批量覆盖。

## 发布与旧域名

内容迁移使用现有站点和套餐。迁移不修改 DNS，也不停止 VitePress 部署。

旧客户端仍会请求 `https://docs-appports.shimoko.com/sponsors.json`，也会打开该域名下的 `.html` 文档和锚点。原域名的 JSON 响应必须保持可用；若以后把旧域名切换到 GitBook，需先为 `/sponsors.json` 保留转发，并验证旧页面重定向。`docs/public/latest.json` 也继续随原部署保留。

发布前应检查 GitBook 预览的首页、挂载迁移、隐私政策、许可、赞助、语言切换、图片、Mermaid 与旧地址跳转。最终域名和托管方式改变时，隐私政策中有关站点及统计服务的描述应据实际部署复核。
