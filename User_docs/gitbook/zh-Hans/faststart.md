# 快速开始

## 安装 AppPorts <a href="#安装-appports" id="安装-appports"></a>

开始使用前，请先确认满足以下条件：

1. 准备一个稳定可用的外部存储设备，例如移动硬盘或外置 SSD。
2. Mac 运行 macOS 12.0（Monterey）或更高版本。

### 下载 <a href="#下载" id="下载"></a>

前往 [GitHub Releases](https://github.com/wzh4869/AppPorts/releases) 下载最新版 `.dmg` 安装包。

{% hint style="success" %}
**下载备用地址**

如果 GitHub Releases 无法访问，可通过[直链网盘](https://file.shimoko.com/AppPorts)获取安装包。
{% endhint %}

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/download.gif?sign=Xb9FOEqPxR8Q7WLixKzg5NCYcjVzmzq2eh0634xGdG0=:0)


### 安装并启动 <a href="#安装并启动" id="安装并启动"></a>

1. 打开下载好的 `.dmg` 安装包。
2. 将 AppPorts 拖入 `Applications` 文件夹。
3. 从 `Applications` 文件夹或 Launchpad 启动 AppPorts。

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/install.gif?sign=dg-gU67tz19m6DGdI3NywEAcuqKnyTpWGas0YhZeGfM=:0)


### 必要授权 <a href="#必要授权" id="必要授权"></a>

首次运行时，AppPorts 需要**完全磁盘访问权限**，用于读取和修改 `/Applications` 目录。

1. 打开系统设置 → 隐私与安全性 → 完全磁盘访问权限。
2. 点击 `+` 按钮，添加 AppPorts，并打开对应开关。
3. 重新启动 AppPorts，使授权生效。

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/outh.gif?sign=fTXqbKCR_tZBKDb6p1DziuJYjD9NZAJk-Zsw7c4oOJM=:0)
   
#### App Store 应用自更新授权 <a href="#app-store-应用自更新授权" id="app-store-应用自更新授权"></a>

如果使用 macOS 15.1（Sequoia）或更高版本，并希望 App Store 应用安装到外部存储后仍可正常更新，请在 App Store 中开启「下载并安装大型 App 到独立存储盘」。AppPorts 会在外部存储中准备对应的 `/Applications` 目录，以便 App Store 在该位置安装和更新应用。

{% hint style="warning" %}
**macOS 15.1 之前的限制**

macOS 15.1 之前的系统不支持 App Store 应用原生安装到外部存储。你仍可在 AppPorts 右上角设置中开启 App Store 应用迁移功能，但后续应用更新需要手动再次迁移，以覆盖外部存储上的旧版本。
{% endhint %}

1. 打开 App Store。
2. 在菜单栏中进入 App Store 设置。
3. 勾选「下载并安装大型 App 到独立存储盘」，并选择与 AppPorts 外部应用库相同的外部存储设备。
 
![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appstore.gif?sign=JwDPVgjgPb3AulPjZq6Y2KgubkHxmGNqaUawCBRhCEM=:0)
