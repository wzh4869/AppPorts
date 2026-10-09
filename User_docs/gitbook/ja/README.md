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
  cover:
    visible: true
    size: "background"
icon: "book-open"
cover: ".gitbook/assets/home-cover.svg"
coverY: 0
---

# AppPorts

## 外部ドライブで世界を救う <a href="#外部ドライブで世界を救う" id="外部ドライブで世界を救う"></a>

AppPorts のインストールからアプリ・データの移行、日常のメンテナンスまで。

<button type="button" class="button primary" data-action="ask" data-icon="gitbook-assistant">AppPorts について何を知りたいですか？</button>

<a href="faststart.md" class="button primary">クイックスタート</a> <a href="AppPorts.md" class="button secondary">はじめに</a>

<h3 align="center">ここから始める <a href="#kokokarameru" id="kokokarameru"></a></h3>

<p align="center">初回の利用、アプリ移行、データ移行から、目的に合うガイドを選びます。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><h4>はじめる <a href="#start-1" id="start-1"></a></h4></td><td>AppPorts の概要、インストール、権限、基本設定を確認します。</td><td><a data-mention href="faststart.md">クイックスタート</a></td><td><a data-mention href="AppPorts.md">はじめに</a></td><td><a data-mention href="settings.md">設定</a></td></tr>
<tr><td><i class="fa-layer-group"></i></td><td><h4>アプリ移行 <a href="#start-2" id="start-2"></a></h4></td><td>アプリの移行・復元手順と、種類別の移行戦略を確認します。</td><td><a data-mention href="core.md">主な機能</a></td><td><a data-mention href="migration-strategy/portal.md">移行戦略</a></td><td><a data-mention href="migration-strategy/strategy-map.md">アプリの種類と戦略</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><h4>データ移行 <a href="#start-3" id="start-3"></a></h4></td><td>データディレクトリの操作、ツールデータの検出、コンテナのマウント移行を確認します。</td><td><a data-mention href="datamigrae/operation.md">データ移行ガイド</a></td><td><a data-mention href="datamigrae/tools.md">ツールディレクトリ検出</a></td><td><a data-mention href="datamigrae/mount-migration.md">コンテナのマウント移行</a></td></tr>
</tbody>
</table>

***

<h3 align="center">ストレージと日常の管理 <a href="#storage-and-maintenance" id="storage-and-maintenance"></a></h3>

<p align="center">外部ドライブの要件、更新情報、問題の確認手順を探します。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-hard-drive"></i></td><td><h4>外部ストレージ <a href="#maintain-1" id="maintain-1"></a></h4></td><td>外部ドライブの選び方、APFS が必要な場面、互換性の制限を確認します。</td><td><a data-mention href="storage-guide.md">外部ストレージガイド</a></td><td><a data-mention href="why-apfs.md">APFS の要件</a></td><td><a data-mention href="limitations.md">互換性と制限</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><h4>更新とメンテナンス <a href="#maintain-2" id="maintain-2"></a></h4></td><td>アプリの更新、macOS 27 の変更、コンテナデータと署名 ID の関係を確認します。</td><td><a data-mention href="migration-strategy/updater-detection.md">自動更新アプリの検出</a></td><td><a data-mention href="macos-27.md">macOS 27 へのアップグレード</a></td><td><a data-mention href="datamigrae/container-identity.md">コンテナデータと署名</a></td></tr>
<tr><td><i class="fa-life-ring"></i></td><td><h4>トラブルシューティング <a href="#maintain-3" id="maintain-3"></a></h4></td><td>症状別の確認手順、よくある質問、ログの調べ方を探します。</td><td><a data-mention href="troubleshooting.md">トラブルシューティング</a></td><td><a data-mention href="faq.md">よくある質問</a></td><td><a data-mention href="logging.md">ログと診断</a></td></tr>
</tbody>
</table>

***

<h3 align="center">主な機能を知る <a href="#naworu" id="naworu"></a></h3>

<p align="center">AppPorts の主な 3 つの機能を紹介します。</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>矢印のない移行</strong></td><td>大容量アプリをワンクリックで外部ストレージへ移行。ローカルには軽量な起動用シェルだけを残し、Finder にショートカット矢印を表示せず、Launchpad とアプリメニューも通常どおり使えます。</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>自動更新からの保護</strong></td><td>Sparkle、Electron などの自動更新アプリを検出し、「Locked Migration」を提供します。ローカルの新版が外部のコピーより新しい場合は「移行待ち」と表示します。</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>データディレクトリの管理</strong></td><td>~/Library/ のサブディレクトリや ~/.npm などを外部ストレージへ移行できます。WeChat のチャット履歴などのサンドボックス内のコンテナデータは、署名を変更せず APFS の外部ドライブにマウント移行します。</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>

***

<h3 align="center">さらに詳しく <a href="#keep-exploring" id="keep-exploring"></a></h3>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-clock-rotate-left"></i></td><td><h4>変更履歴 <a href="#explore-1" id="explore-1"></a></h4></td><td>バージョンごとの変更点と修正内容を確認します。</td><td><a href="changelog.md">changelog.md</a></td></tr>
<tr><td><i class="fa-flask"></i></td><td><h4>実験記録 <a href="#explore-2" id="explore-2"></a></h4></td><td>サンドボックス、マウント、ドライブ取り外し、起動時の実験記録を確認します。</td><td><a href="research/README.md">research/README.md</a></td></tr>
<tr><td><i class="fa-code-pull-request"></i></td><td><h4>コントリビューション <a href="#explore-3" id="explore-3"></a></h4></td><td>開発、テスト、ドキュメント改善への参加方法を確認します。</td><td><a href="contributing.md">contributing.md</a></td></tr>
</tbody>
</table>
