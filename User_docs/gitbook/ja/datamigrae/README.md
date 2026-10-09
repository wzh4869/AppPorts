---
icon: "database"
description: "データディレクトリを確認し、移行方法、復元、署名の扱いを理解します。"
layout:
  width: "wide"
  outline:
    visible: false
  pagination:
    visible: false
  metadata:
    visible: false
---

# データ移行

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-diagram-project"></i></td><td><strong>基本実装</strong></td><td>データディレクトリの検出と移行の基本的な仕組みを確認します。</td><td><a href="baseinfo.md">baseinfo.md</a></td></tr>
<tr><td><i class="fa-terminal"></i></td><td><strong>ツールディレクトリ検出</strong></td><td>検出対象となるツールのデータディレクトリを確認します。</td><td><a href="tools.md">tools.md</a></td></tr>
<tr><td><i class="fa-arrows-left-right"></i></td><td><strong>操作ガイド</strong></td><td>データディレクトリを移行・復元する手順を確認します。</td><td><a href="operation.md">operation.md</a></td></tr>
<tr><td><i class="fa-hard-drive"></i></td><td><strong>マウント移行：コンテナデータを外部ドライブに置く</strong></td><td>サンドボックスのコンテナデータを外部 APFS ドライブへ移行します。</td><td><a href="mount-migration.md">mount-migration.md</a></td></tr>
<tr><td><i class="fa-shield-halved"></i></td><td><strong>再署名とクラッシュ防止</strong></td><td>再署名の適用範囲とクラッシュ防止について確認します。</td><td><a href="resign.md">resign.md</a></td></tr>
</tbody>
</table>
