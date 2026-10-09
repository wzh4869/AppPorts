---
description: "安裝、遷移與日常維護：AppPorts 的 macOS 使用指南。"
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

## 外接硬碟拯救世界 <a href="#外接硬碟拯救世界" id="外接硬碟拯救世界"></a>

安裝、遷移與日常維護：AppPorts 的 macOS 使用指南。

<button type="button" class="button primary" data-action="ask" data-icon="gitbook-assistant">你想了解 AppPorts 的哪方面？</button>

<a href="faststart.md" class="button primary">快速開始</a> <a href="AppPorts.md" class="button secondary">簡介</a>

<h3 align="center">從這裡開始 <a href="#cong-zhe-li-kai-shi" id="cong-zhe-li-kai-shi"></a></h3>

<p align="center">從首次使用到應用程式與資料遷移，依目前任務選擇指南。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><h4>首次使用 <a href="#start-1" id="start-1"></a></h4></td><td>了解 AppPorts，查看安裝、授權與基本設定。</td><td><a data-mention href="faststart.md">快速開始</a></td><td><a data-mention href="AppPorts.md">AppPorts 簡介</a></td><td><a data-mention href="settings.md">設定</a></td></tr>
<tr><td><i class="fa-layer-group"></i></td><td><h4>應用程式遷移 <a href="#start-2" id="start-2"></a></h4></td><td>了解應用程式的遷移、還原與不同類型的對應策略。</td><td><a data-mention href="core.md">核心功能</a></td><td><a data-mention href="migration-strategy/portal.md">遷移策略</a></td><td><a data-mention href="migration-strategy/strategy-map.md">應用類型與策略</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><h4>資料遷移 <a href="#start-3" id="start-3"></a></h4></td><td>查閱資料目錄操作、工具資料識別與容器掛載遷移指南。</td><td><a data-mention href="datamigrae/operation.md">遷移操作指南</a></td><td><a data-mention href="datamigrae/tools.md">工具目錄識別</a></td><td><a data-mention href="datamigrae/mount-migration.md">容器掛載遷移</a></td></tr>
</tbody>
</table>

***

<h3 align="center">儲存與日常維護 <a href="#storage-and-maintenance" id="storage-and-maintenance"></a></h3>

<p align="center">查看外接磁碟要求、更新說明與常見問題的排查方式。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-hard-drive"></i></td><td><h4>外接儲存裝置 <a href="#maintain-1" id="maintain-1"></a></h4></td><td>了解外接磁碟怎麼選、哪些情境需要 APFS，以及相容性限制。</td><td><a data-mention href="storage-guide.md">外接儲存裝置指南</a></td><td><a data-mention href="why-apfs.md">APFS 要求</a></td><td><a data-mention href="limitations.md">相容性與限制</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><h4>更新與維護 <a href="#maintain-2" id="maintain-2"></a></h4></td><td>了解應用程式更新、macOS 27 變化，以及容器資料與簽名身分的關係。</td><td><a data-mention href="migration-strategy/updater-detection.md">自更新應用識別</a></td><td><a data-mention href="macos-27.md">macOS 27 升級說明</a></td><td><a data-mention href="datamigrae/container-identity.md">容器資料與簽名</a></td></tr>
<tr><td><i class="fa-life-ring"></i></td><td><h4>故障排查 <a href="#maintain-3" id="maintain-3"></a></h4></td><td>依症狀查找排查步驟、常見問題解答與日誌診斷方法。</td><td><a data-mention href="troubleshooting.md">故障排除</a></td><td><a data-mention href="faq.md">常見問題</a></td><td><a data-mention href="logging.md">日誌與診斷</a></td></tr>
</tbody>
</table>

***

<h3 align="center">探索核心功能 <a href="#tan-suo-he-xin-gong-neng" id="tan-suo-he-xin-gong-neng"></a></h3>

<p align="center">了解 AppPorts 的三項核心功能。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>無角標遷移</strong></td><td>一鍵將大型應用程式遷移至外接儲存裝置。本機僅保留輕量啟動器殼，Finder 不顯示捷徑箭頭，Launchpad 與應用程式選單正常顯示。</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>自動更新保護</strong></td><td>自動辨識 Sparkle、Electron 等自更新應用程式，提供「锁定遷移」選項；本機新版高於外部舊副本時，會標記為「待遷出」。</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>資料目錄管理</strong></td><td>支援將 ~/Library/ 子目錄、~/.npm 等資料目錄遷移至外接儲存裝置；沙盒容器資料（如微信聊天記錄）透過掛載遷移放到 APFS 外接磁碟，簽名不變更。</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>

***

<h3 align="center">繼續探索 <a href="#keep-exploring" id="keep-exploring"></a></h3>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-clock-rotate-left"></i></td><td><h4>更新日誌 <a href="#explore-1" id="explore-1"></a></h4></td><td>依版本查看變更與修復紀錄。</td><td><a href="changelog.md">changelog.md</a></td></tr>
<tr><td><i class="fa-flask"></i></td><td><h4>實驗紀錄 <a href="#explore-2" id="explore-2"></a></h4></td><td>查閱沙盒、掛載、拔除磁碟與開機時序的實驗紀錄。</td><td><a href="research/README.md">research/README.md</a></td></tr>
<tr><td><i class="fa-code-pull-request"></i></td><td><h4>參與貢獻 <a href="#explore-3" id="explore-3"></a></h4></td><td>了解如何參與開發、測試與文件改進。</td><td><a href="contributing.md">contributing.md</a></td></tr>
</tbody>
</table>
