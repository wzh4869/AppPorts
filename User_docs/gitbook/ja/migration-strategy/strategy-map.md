---
icon: "table-list"
description: "アプリの種類ごとに対応する移行戦略を探します。"
layout:
  width: "default"
  outline:
    visible: true
---

# アプリタイプと戦略

| アプリタイプ | コンテナ分類 | 移行戦略 | ロック保護 | 備考 |
|-------------|------------|---------|----------|------|
| ネイティブ macOS アプリ（自動更新なし） | `standaloneApp` | macOS Stub Portal | なし | 例：Safari、Finder |
| Sparkle 自動更新アプリ | `standaloneApp` | macOS Stub Portal | **あり** | 例：一部の個人開発者アプリ |
| Electron アプリ（`app-update.yml` なし） | `standaloneApp` | macOS Stub Portal | なし | 例：VS Code |
| Electron アプリ（`app-update.yml` あり） | `standaloneApp` | macOS Stub Portal | **あり** | 例：Slack、Discord |
| Electron + Sparkle ハイブリッドアプリ | `standaloneApp` | macOS Stub Portal | **あり** | 両方のフラグが独立して検出される |
| カスタムアップデーターアプリ（Chrome、Edge） | `standaloneApp` | macOS Stub Portal | なし | `LaunchServices`、`KSProductID` などで識別 |
| iOS アプリ（Mac 版） | `standaloneApp` | iOS Stub Portal | なし | `WrappedBundle` からアイコンを抽出；署名なし |
| Mac App Store アプリ | `standaloneApp` | macOS Stub Portal | なし | SIP 保護；再署名不可 |
| 単一アプリコンテナディレクトリ | `singleAppContainer` | Whole App Symlink | なし | `.app` が1つのみのディレクトリ；全体シンボリックリンク |
| アプリスイートディレクトリ（例：Office） | `appSuiteFolder` | Whole App Symlink | 内部アプリによる | `.app` が2つ以上のディレクトリ；全体シンボリックリンク |
| `.app` 以外のパス | — | Whole App Symlink | — | `.app` 以外の拡張子を持つパス |

{% hint style="warning" %}
**⚠️ ロック保護について**

アプリにロックが必要とマークされた場合（`needsLock = true`）、AppPorts は移行完了後に外部ストレージアプリに対して `chflags -R uchg` を実行し、イミュータブルフラグを設定します。これにより自動更新プログラムが外部コピーを削除または変更するのを防止しますが、アプリが自己更新できなくなります。更新する前に AppPorts で手動ロック解除が必要です。
{% endhint %}

{% hint style="success" %}
**💡 カスタムアップデーターアプリがロックされない理由**

Chrome や Edge のようなカスタムアップデーターを使用するアプリはロックされません。これらのアプリのアップデーターは通常、新しいバージョンをローカルの内部ストレージにダウンロードしてインストールします。macOS Stub Portal のリンク隔離特性により、外部ストレージ上のアプリファイルは破損しません。

AppPorts がローカル内部ストレージ上のアプリバージョンが外部ストレージ上のバージョンより新しいことを検出すると、アプリに「移行待ち（外へ）」タグを自動的に付与し、最新バージョンを同期するために再移行を促します。
{% endhint %}
