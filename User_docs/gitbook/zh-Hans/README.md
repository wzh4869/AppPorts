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
icon: "book-open"
---

# AppPorts

## 外置硬盘拯救世界 <a href="#外置硬盘拯救世界" id="外置硬盘拯救世界"></a>

安装、迁移与日常维护：AppPorts 的 macOS 使用指南。

<a href="faststart.md" class="button primary">快速开始</a> <a href="AppPorts.md" class="button secondary">简介</a>

## 从这里开始

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><strong>快速开始</strong></td><td>下载并安装 AppPorts，完成首次启动所需的授权。</td><td><a href="faststart.md">faststart.md</a></td></tr>
<tr><td><i class="fa-hard-drive"></i></td><td><strong>外部存储指南</strong></td><td>了解外置存储的选择、格式与使用要求。</td><td><a href="storage-guide.md">storage-guide.md</a></td></tr>
<tr><td><i class="fa-wrench"></i></td><td><strong>故障排除</strong></td><td>按症状检查权限、迁移状态与修复方法。</td><td><a href="troubleshooting.md">troubleshooting.md</a></td></tr>
</tbody>
</table>

## 探索核心功能

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>无角标迁移</strong></td><td>一键将大型应用迁移至外部存储。本地仅保留轻量启动器壳，Finder 不显示快捷方式箭头，Launchpad 与应用菜单正常显示。</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>自动更新保护</strong></td><td>自动识别 Sparkle、Electron 等自更新应用，提供「锁定迁移」选项；本地新版高于外部旧副本时，会标记为「待迁出」。</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>数据目录管理</strong></td><td>支持将 ~/Library/ 子目录、~/.npm 等数据目录迁移至外部存储；沙盒容器数据（如微信聊天记录）通过挂载迁移放到 APFS 外置盘，签名不动。</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>
