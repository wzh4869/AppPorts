---
description: "安装、迁移与日常维护：AppPorts 的 macOS 使用指南。"
layout:
  width: "wide"
  outline:
    visible: false
  pagination:
    visible: false
  metadata:
    visible: false
  title:
    visible: false
  description:
    visible: false
  cover:
    visible: true
    size: "background"
icon: "book-open"
cover: ".gitbook/assets/home-cover.svg"
coverY: 0
---

# AppPorts

## 外置硬盘拯救世界 <a href="#外置硬盘拯救世界" id="外置硬盘拯救世界"></a>

安装、迁移与日常维护：AppPorts 的 macOS 使用指南。

<button type="button" class="button primary" data-action="ask" data-icon="gitbook-assistant">你想了解 AppPorts 的哪方面？</button>

<a href="faststart.md" class="button primary">快速开始</a> <a href="AppPorts.md" class="button secondary">简介</a>

<h3 align="center">从这里开始 <a href="#cong-zhe-li-kai-shi" id="cong-zhe-li-kai-shi"></a></h3>

<p align="center">从首次使用到应用与数据迁移，按当前任务选择指南。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><h4>首次使用 <a href="#start-1" id="start-1"></a></h4></td><td>了解 AppPorts，查看安装、授权与基本设置。</td><td><a data-mention href="faststart.md">快速开始</a></td><td><a data-mention href="AppPorts.md">AppPorts 简介</a></td><td><a data-mention href="settings.md">设置</a></td></tr>
<tr><td><i class="fa-layer-group"></i></td><td><h4>应用迁移 <a href="#start-2" id="start-2"></a></h4></td><td>了解应用的迁移、还原与不同类型的对应策略。</td><td><a data-mention href="core.md">核心功能</a></td><td><a data-mention href="migration-strategy/portal.md">迁移策略</a></td><td><a data-mention href="migration-strategy/strategy-map.md">应用类型与策略</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><h4>数据迁移 <a href="#start-3" id="start-3"></a></h4></td><td>查阅数据目录操作、工具数据识别与容器挂载迁移指南。</td><td><a data-mention href="datamigrae/operation.md">迁移操作指南</a></td><td><a data-mention href="datamigrae/tools.md">工具目录识别</a></td><td><a data-mention href="datamigrae/mount-migration.md">容器挂载迁移</a></td></tr>
</tbody>
</table>

***

<h3 align="center">存储与日常维护 <a href="#storage-and-maintenance" id="storage-and-maintenance"></a></h3>

<p align="center">查看外置盘要求、更新说明与常见问题的排查路径。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-hard-drive"></i></td><td><h4>外置存储 <a href="#maintain-1" id="maintain-1"></a></h4></td><td>了解外置盘怎么选、哪些场景需要 APFS，以及兼容性限制。</td><td><a data-mention href="storage-guide.md">外部存储指南</a></td><td><a data-mention href="why-apfs.md">APFS 要求</a></td><td><a data-mention href="limitations.md">兼容性与限制</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><h4>更新与维护 <a href="#maintain-2" id="maintain-2"></a></h4></td><td>了解应用更新、macOS 27 变化，以及容器数据与签名身份的关系。</td><td><a data-mention href="migration-strategy/updater-detection.md">自更新应用识别</a></td><td><a data-mention href="macos-27.md">macOS 27 升级说明</a></td><td><a data-mention href="datamigrae/container-identity.md">容器数据与签名</a></td></tr>
<tr><td><i class="fa-life-ring"></i></td><td><h4>故障排查 <a href="#maintain-3" id="maintain-3"></a></h4></td><td>按症状查找排查步骤、常见问题解答与日志诊断方法。</td><td><a data-mention href="troubleshooting.md">故障排除</a></td><td><a data-mention href="faq.md">常见问题</a></td><td><a data-mention href="logging.md">日志与诊断</a></td></tr>
</tbody>
</table>

***

<h3 align="center">探索核心功能 <a href="#tan-suo-he-xin-gong-neng" id="tan-suo-he-xin-gong-neng"></a></h3>

<p align="center">了解 AppPorts 的三项核心功能。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>无角标迁移</strong></td><td>一键将大型应用迁移至外部存储。本地仅保留轻量启动器壳，Finder 不显示快捷方式箭头，Launchpad 与应用菜单正常显示。</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>自动更新保护</strong></td><td>自动识别 Sparkle、Electron 等自更新应用，提供「锁定迁移」选项；本地新版高于外部旧副本时，会标记为「待迁出」。</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>数据目录管理</strong></td><td>支持将 ~/Library/ 子目录、~/.npm 等数据目录迁移至外部存储；沙盒容器数据（如微信聊天记录）通过挂载迁移放到 APFS 外置盘，签名不动。</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>

***

<h3 align="center">继续探索 <a href="#keep-exploring" id="keep-exploring"></a></h3>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-clock-rotate-left"></i></td><td><h4>更新日志 <a href="#explore-1" id="explore-1"></a></h4></td><td>按版本查看改动与修复记录。</td><td><a href="changelog.md">changelog.md</a></td></tr>
<tr><td><i class="fa-flask"></i></td><td><h4>实验记录 <a href="#explore-2" id="explore-2"></a></h4></td><td>查阅沙盒、挂载、拔盘与开机时序的实验记录。</td><td><a href="research/README.md">research/README.md</a></td></tr>
<tr><td><i class="fa-code-pull-request"></i></td><td><h4>参与贡献 <a href="#explore-3" id="explore-3"></a></h4></td><td>了解如何参与开发、测试与文档改进。</td><td><a href="contributing.md">contributing.md</a></td></tr>
</tbody>
</table>
