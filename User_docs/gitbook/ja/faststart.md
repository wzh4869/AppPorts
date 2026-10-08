# はじめる

## AppPorts のインストール <a href="#appports-のインストール" id="appports-のインストール"></a>

AppPorts のインストールには、以下の2つの前提条件が必要です：
1. 安定した外部ストレージデバイス（ハードドライブなど）
2. macOS 12.0（Monterey）以上のオペレーティングシステム

### ダウンロード <a href="#ダウンロード" id="ダウンロード"></a>

[Github releases](https://github.com/wzh4869/AppPorts/releases) ページから最新の .dmg インストーラーをダウンロードしてください

{% hint style="success" %}

上記のリンクが開けない場合は、こちらのリンクからインストーラーを入手してください[直接ダウンロード](https://file.shimoko.com/AppPorts)
{% endhint %}

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/download.gif?sign=Xb9FOEqPxR8Q7WLixKzg5NCYcjVzmzq2eh0634xGdG0=:0)


### インストールと起動 <a href="#インストールと起動" id="インストールと起動"></a>
1. .dmg インストーラーを開く
2. アプリケーションを Applications フォルダにドラッグ
3. アプリケーションを起動

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/install.gif?sign=dg-gU67tz19m6DGdI3NywEAcuqKnyTpWGas0YhZeGfM=:0)


### 必要な権限 <a href="#必要な権限" id="必要な権限"></a>

初回起動時、AppPorts は `/Applications` ディレクトリの読み取りと変更のためにフルディスクアクセス権限が必要です。
1. システム設定 → プライバシーとセキュリティを開きます。
フルディスクアクセスを選択します。
2. + ボタンをクリックし、AppPorts を追加してからスイッチをオンに切り替えます。
3. AppPorts を再起動します。

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/outh.gif?sign=fTXqbKCR_tZBKDb6p1DziuJYjD9NZAJk-Zsw7c4oOJM=:0)

#### App Store アプリの自動更新権限 <a href="#app-store-アプリの自動更新権限" id="app-store-アプリの自動更新権限"></a>

macOS 15.1（Sequoia）以降のユーザーは、App Store で「大容量アプリを外付けドライブにダウンロードしてインストール」を有効にし、AppPorts が外部ストレージの `/Applications` フォルダを作成して App Store アプリの自動更新をサポートできるようにする必要があります。
{% hint style="warning" %}
**⚠️ macOS 15.1（Sequoia）以前のシステムでは OS の制限によりこの機能はサポートされていません**

AppPorts の設定で「App Store アプリの移行を許可」設定を有効にする必要があります。以降のアプリ更新には手動での再移行による上書きが必要です。
{% endhint %}

1. App Store を開きます
2. ステータスバーで設定をクリックし、「大容量アプリを外付けドライブにダウンロードしてインストール」にチェックを入れ、AppPorts の外部ストレージライブラリと同じ外部ストレージデバイスを選択します

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appstore.gif?sign=JwDPVgjgPb3AulPjZq6Y2KgubkHxmGNqaUawCBRhCEM=:0)
