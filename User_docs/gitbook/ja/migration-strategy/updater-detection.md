# 自動更新検出

## Electron アプリ検出 <a href="#electron-アプリ検出" id="electron-アプリ検出"></a>

AppPorts は、以下の3つの検出条件（優先度順にチェック、ショートサーキット評価）を通じて Electron アプリを識別します：

| # | 検出項目 | パス / パターン |
|---|---------|----------------|
| 1 | Electron フレームワーク | `Contents/Frameworks/Electron Framework.framework` ディレクトリが存在する |
| 2 | Electron Helper バリアント | `Contents/Frameworks/` 以下に `Electron Helper` を含むエントリが存在する |
| 3 | Info.plist 識別キー | `Contents/Info.plist` に `ElectronDefaultApp` または `electron` キーが存在する |

### Electron 自動更新検出 <a href="#electron-自動更新検出" id="electron-自動更新検出"></a>

さらに、`Contents/Resources/app-update.yml` ファイル（`electron-updater` の設定ファイル）の存在をチェックします。存在する場合、その Electron アプリは自動更新機能を持つとマークされます。

## Sparkle アプリ検出 <a href="#sparkle-アプリ検出" id="sparkle-アプリ検出"></a>

AppPorts は、以下の3つの検出条件を通じて Sparkle アプリを識別します：

| # | 検出項目 | パス / パターン |
|---|---------|----------------|
| 1 | Sparkle フレームワーク | `Contents/Frameworks/Sparkle.framework` または `Contents/Frameworks/Squirrel.framework` が存在する |
| 2 | アップデーターバイナリファイル | `Contents/MacOS/` または `Contents/Frameworks/` 以下に `shipit`、`autoupdate`、`updater`、`update` に一致するファイルが存在する |
| 3 | Info.plist Sparkle キー | `Contents/Info.plist` に以下のいずれかのキーが存在する：`SUFeedURL`、`SUPublicDSAKeyFile`、`SUPublicEDKey`、`SUScheduledCheckInterval`、`SUAllowsAutomaticUpdates` |

{% hint style="warning" %}
**⚠️ Electron アプリの特別な処理**

アプリが Electron アプリとして識別された場合、検出条件 #2（アップデーターバイナリファイル）はスキップされ、`electron-updater` の `updater` バイナリが Sparkle として誤検出されるのを回避します。
{% endhint %}

## ハイブリッド Electron + Sparkle アプリ <a href="#ハイブリッド-electron-sparkle-アプリ" id="ハイブリッド-electron-sparkle-アプリ"></a>

一部のアプリは Electron フレームワークと Sparkle アップデーターの両方を含んでいます。AppPorts は両方のフラグを独立して検出し、`isElectron` と `isSparkle` の両方を `true` にすることができます。

### 検出ロジック <a href="#検出ロジック" id="検出ロジック"></a>

```text
isElectron = 3つの Electron 検出条件のいずれかを満たす
isSparkle  = 3つの Sparkle 検出条件のいずれかを満たす（Electron アプリは条件 #2 をスキップ）
```

2つのフラグは独立しており、同時に true になることができます。

### 移行後の動作 <a href="#移行後の動作" id="移行後の動作"></a>

| 属性 | 判定条件 |
|------|---------|
| `hasSelfUpdater` | `isSparkle` または（`isElectron` かつ `app-update.yml` が存在）またはカスタムアップデーターが存在 |
| `needsLock` | `isSparkle` または（`isElectron` かつ `app-update.yml` が存在） |

`needsLock` が `true` の場合、AppPorts は移行完了後に外部ストレージアプリに対して `chflags -R uchg`（イミュータブルフラグの設定）を実行し、自動更新プログラムが外部コピーを削除または変更するのを防止します。

## カスタムアップデーター検出 <a href="#カスタムアップデーター検出" id="カスタムアップデーター検出"></a>

Sparkle でも Electron でもないネイティブ自動更新アプリ（例：Chrome、Edge、Parallels）について、AppPorts は以下のパターンを通じて識別します：

| 検出パス | マッチングパターン | 代表的なアプリ |
|---------|------------------|---------------|
| `Contents/Library/LaunchServices/` | ファイル名に `update` が含まれる | Chrome、Edge、Thunderbird |
| `Contents/MacOS/` | バイナリファイル名に `update` または `upgrade` が含まれる（`electron` は除外） | Parallels、Thunderbird |
| `Contents/SharedSupport/` | ファイル名に `update` が含まれる | WPS Office |
| `Contents/Info.plist` | `KSProductID` キーが存在する | Google Keystone（Chrome） |

## レガシー戦略の識別 <a href="#レガシー戦略の識別" id="レガシー戦略の識別"></a>

復元またはリンク解除の際、AppPorts は旧バージョンで作成されたレガシーエントリを識別する必要があります：

| ローカル構造の特徴 | 識別結果 |
|-------------------|---------|
| ルートパスがシンボリックリンク | `wholeAppSymlink` |
| `Contents/` がシンボリックリンク | `deepContentsWrapper` |
| `Contents/Info.plist` がシンボリックリンク | `wholeAppSymlink`（レガシー Sparkle ハイブリッドスキーム） |
| `Contents/Frameworks/` がシンボリックリンク | `wholeAppSymlink`（レガシー Electron ハイブリッドスキーム） |
| `Contents/MacOS/launcher` が存在する | `stubPortal` |
| 上記のいずれにも一致しない | AppPorts で管理されていない |
