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
icon: "book-open"
---

# AppPorts

## 外接硬碟拯救世界 <a href="#外接硬碟拯救世界" id="外接硬碟拯救世界"></a>

<a href="faststart.md" class="button primary">快速開始</a> <a href="AppPorts.md" class="button secondary">簡介</a>

**從這裡開始**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><strong>快速開始</strong></td><td>下載並安裝 AppPorts，完成首次啟動所需的授權。</td><td><a href="faststart.md">faststart.md</a></td></tr>
<tr><td><i class="fa-hard-drive"></i></td><td><strong>外接儲存裝置指南</strong></td><td>了解外接儲存裝置的選擇、格式與使用要求。</td><td><a href="storage-guide.md">storage-guide.md</a></td></tr>
<tr><td><i class="fa-wrench"></i></td><td><strong>故障排除</strong></td><td>依症狀檢查權限、遷移狀態與修復方法。</td><td><a href="troubleshooting.md">troubleshooting.md</a></td></tr>
</tbody>
</table>

**探索核心功能**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>無角標遷移</strong></td><td>一鍵將大型應用程式遷移至外接儲存裝置。本機僅保留輕量啟動器殼，Finder 不顯示捷徑箭頭，Launchpad 與應用程式選單正常顯示。</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>自動更新保護</strong></td><td>自動辨識 Sparkle、Electron 等自更新應用程式，提供「锁定遷移」選項；本機新版高於外部舊副本時，會標記為「待遷出」。</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>資料目錄管理</strong></td><td>支援將 ~/Library/ 子目錄、~/.npm 等資料目錄遷移至外接儲存裝置；沙盒容器資料（如微信聊天記錄）透過掛載遷移放到 APFS 外接磁碟，簽名不變更。</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>
