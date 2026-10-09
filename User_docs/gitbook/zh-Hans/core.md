---
icon: "layer-group"
layout:
  width: "default"
  outline:
    visible: true
---

# 核心功能

本页介绍 AppPorts 最常用的应用迁移功能。若需要迁移应用数据目录，请参阅[数据迁移](datamigrae/baseinfo.md)。

## 迁移应用至外部存储 <a href="#迁移应用至外部存储" id="迁移应用至外部存储"></a>

1. 在本地应用列表中选择一个应用；如需选择多个应用，可按住 `Command` 后逐个点击，或使用鼠标拖选。
2. 点击底部的「迁移至外部」按钮。
3. 等待迁移完成。

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/gonomoral.gif?sign=tzb_Y7YRR9uTc4uunpWXJWYs8dOXLEa0S0AQH-qcB4I=:0)

{% hint style="success" %}
**完成前的短暂停顿**

进度到达 100% 附近时，AppPorts 可能会停顿一至两秒，用于创建本地入口并完成收尾检查。
{% endhint %}

### 更新后的本地应用 <a href="#更新后的本地应用" id="更新后的本地应用"></a>

如果某个已迁移应用后来被更新程序重新安装到本地，而外部存储中仍保留旧版本，AppPorts 会在可确认版本关系时将本地应用标记为「待迁出」。此时再次执行迁移，会将本地新版迁移到外部存储并替换外部旧副本。

AppPorts 只会在确认目标是同一应用的旧副本，或目标是 AppPorts 创建的旧入口/迁移残留时自动清理外部目标。若外部位置存在无法确认归属的真实应用，迁移会停止并提示冲突，不会直接覆盖。

## 将外部存储应用迁回本地 <a href="#将外部存储应用迁回本地" id="将外部存储应用迁回本地"></a>

1. 在外部应用库中选择要恢复的应用。
2. 点击「迁回本地」。
3. 等待 AppPorts 将应用复制回本地并移除外部链接。

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/qianhui.gif?sign=VDEq_lQvfhnb1vhUljwh3PVhNFkwjpKcRAeQ-Ht5Mnc=:0)

{% hint style="warning" %}
**本地同名项目保护**

迁回本地时，如果 `/Applications` 中已经存在同名真实应用，或存在不属于当前外部应用的符号链接，AppPorts 会停止还原并提示冲突。只有 AppPorts 能识别为当前应用入口的本地壳或旧迁移入口才会被自动清理。
{% endhint %}

## 将外部存储应用链接回本地 <a href="#将外部存储应用链接回本地" id="将外部存储应用链接回本地"></a>

如果应用已经位于外部存储，但本地没有可启动入口，可使用链接功能重新建立入口。

1. 在外部应用库中选择应用。
2. 点击「链接回本地」。
3. 完成后，可像普通本地应用一样从 Finder、Launchpad 或应用菜单启动。

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/linkback.gif?sign=3xdVe7IFYcMfwNt1K9WMk8ZQYIlNMWngjZoTkNwA610=:0)

## 解除链接 <a href="#解除链接" id="解除链接"></a>

在已链接应用列表中，点击目标应用右侧的「解除」按钮即可移除本地入口。解除链接不会删除外部存储上的真实应用。

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/jiechu.gif?sign=CLDMEQxHts1S2mBEnka9HUYT2XMzcnBwX1Sjfas9Dho=:0)
