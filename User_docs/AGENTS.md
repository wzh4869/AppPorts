# AppPorts 文档站

本文件只约束 User_docs。应用源码遵循仓库根目录规则。

- 文档仅维护简体中文、繁体中文和英文。docs 根目录中文是内容基准，zh-Hant 与 en 保存完整译文；每种语言须包含同一组 29 篇正文与固定章节 ID。
- .content、public、out 是生成产物。仅编辑 docs Markdown、配置与站点源码。
- 目录与正文深度沿用已批准结构。操作、原理、博客、历史归档分别组织，名词解释最后。翻译不能省略实验条件、失败、限制、政策或历史功能。
- 参考 https://developers.google.com/style：面向普通用户，适用情况、步骤、结果与问题入口明确，按钮名称与应用一致，不做无证据的承诺。
- 实验只呈现条件、过程、结果与限制；不包含对话、个人账号或真实个人路径。
- 语言切换使用站内对应文章。退出语言、旧站 .html 地址和合并文章不做重定向或语言回退，不重新加入 VitePress、GitBook 或兼容映射。
- 开发：npm ci；npm run docs:dev。编辑正文后重新生成内容。部署 npm run docs:build 生成的 out，具体见 README.md。
- 验证：npm run docs:build；npm run docs:typecheck；npm run docs:check；浏览器检查三语搜索、主题、手机导航、语言切换、Markdown 导出及旧地址确实不存在。
- 保留 sponsors.json、latest.json、logo.png 的站点根路径；它们供应用和网页使用。
- 决策笔记只写根目录 .agents/notes，遵循根目录 vendored skill。
