---
description: "AppPorts のインストールからアプリ・データの移行、日常のメンテナンスまで。"
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

## 外部ドライブで世界を救う <a href="#外部ドライブで世界を救う" id="外部ドライブで世界を救う"></a>

AppPorts のインストールからアプリ・データの移行、日常のメンテナンスまで。

<a href="faststart.md" class="button primary">クイックスタート</a> <a href="AppPorts.md" class="button secondary">はじめに</a>

## ここから始める

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><strong>クイックスタート</strong></td><td>AppPorts をダウンロードしてインストールし、初回起動に必要な権限を設定します。</td><td><a href="faststart.md">faststart.md</a></td></tr>
<tr><td><i class="fa-hard-drive"></i></td><td><strong>外部ストレージガイド</strong></td><td>外部ドライブの選び方、フォーマット、使用条件を確認します。</td><td><a href="storage-guide.md">storage-guide.md</a></td></tr>
<tr><td><i class="fa-wrench"></i></td><td><strong>トラブルシューティング</strong></td><td>症状に応じて権限や移行状態を確認し、修復方法を探します。</td><td><a href="troubleshooting.md">troubleshooting.md</a></td></tr>
</tbody>
</table>

## 主な機能を知る

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>矢印のない移行</strong></td><td>大容量アプリをワンクリックで外部ストレージへ移行。ローカルには軽量な起動用シェルだけを残し、Finder にショートカット矢印を表示せず、Launchpad とアプリメニューも通常どおり使えます。</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>自動更新からの保護</strong></td><td>Sparkle、Electron などの自動更新アプリを検出し、「Locked Migration」を提供します。ローカルの新版が外部のコピーより新しい場合は「移行待ち」と表示します。</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>データディレクトリの管理</strong></td><td>~/Library/ のサブディレクトリや ~/.npm などを外部ストレージへ移行できます。WeChat のチャット履歴などのサンドボックス内のコンテナデータは、署名を変更せず APFS の外部ドライブにマウント移行します。</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>
