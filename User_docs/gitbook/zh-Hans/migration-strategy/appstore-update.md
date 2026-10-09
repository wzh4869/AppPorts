---
icon: "arrows-rotate"
description: "管理 App Store 应用迁移后的更新。"
layout:
  width: "default"
  outline:
    visible: true
---

# App Store 应用更新策略

App Store 应用的更新行为与第三方应用存在明显差异。AppPorts 会根据 macOS 版本采用不同的迁移与更新策略。

## macOS 15.1+：原生外置安装 <a href="#macos-15-1-原生外置安装" id="macos-15-1-原生外置安装"></a>

macOS 15.1（Sequoia）引入了 App Store 应用原生安装到外部存储的功能。AppPorts 利用这一机制，无需额外迁移操作即可实现外置安装与原地更新。

### 工作原理 <a href="#工作原理" id="工作原理"></a>

1. 用户在 App Store 设置中启用「下载并安装大型 App 到独立存储盘」。
2. App Store 将应用直接安装到外部存储的 `/Volumes/{drive}/Applications/` 目录。如果该目录不存在，AppPorts 会自动创建，确保 App Store 可正常向此路径安装应用。
3. AppPorts 扫描并识别该目录下的 App Store 应用。
4. 应用更新由 App Store 直接在外部存储上增量完成，无需迁回本地。外部真实应用与本地入口壳相互独立，因此不会产生传统迁移方式中的更新覆盖问题。

### 配置步骤 <a href="#配置步骤" id="配置步骤"></a>

1. 打开 App Store。
2. 在菜单栏中进入 App Store 设置。
3. 勾选「下载并安装大型 App 到独立存储盘」。
4. 选择与 AppPorts 外部应用库相同的外部存储设备。

{% hint style="success" %}
**存储选择**

所选外置存储必须与 AppPorts 的外部应用库位于同一磁盘卷上。AppPorts 通过检测 `/Volumes/{drive}/Applications/` 目录自动识别这些应用。
{% endhint %}

### 适用条件 <a href="#适用条件" id="适用条件"></a>

| 要求 | 说明 |
|------|------|
| 系统版本 | macOS 15.1（Sequoia）及以上 |
| App Store 设置 | 已开启「下载并安装大型 App 到独立存储盘」 |
| 外部存储 | 与 AppPorts 应用库位于同一磁盘卷 |

## macOS 15.1 以下：二次迁移覆盖 <a href="#macos-15-1-以下-二次迁移覆盖" id="macos-15-1-以下-二次迁移覆盖"></a>

macOS 15.1 之前的系统不支持 App Store 应用原生安装到外部存储。AppPorts 可通过手动迁移方案实现外置存放，但应用更新后需要再次迁移。

### 工作原理 <a href="#工作原理-1" id="工作原理-1"></a>

1. 用户在 AppPorts 设置中开启「App Store 应用迁移」开关。
2. AppPorts 将 App Store 应用迁移至外部存储，并使用 macOS Stub Portal 策略创建本地入口。
3. App Store 检测到应用位于外部存储时，更新会安装到本地 `/Applications/` 目录。
4. 更新完成后，AppPorts 检测到版本差异，并提示用户重新迁移以覆盖外部副本。

### 配置步骤 <a href="#配置步骤-1" id="配置步骤-1"></a>

1. 打开 AppPorts → 右上角设置。
2. 找到「App Store 与 iOS 设置」区域。
3. 开启「App Store 应用迁移」开关。
4. 执行应用迁移。

### 更新流程 <a href="#更新流程" id="更新流程"></a>

```text
App Store 发布更新
  → 更新安装到本地 /Applications/
  → AppPorts 检测到版本差异
  → 标记应用为「待迁出」
  → 用户手动重新迁移
  → 新版本覆盖外部存储上的旧版本
```

### 适用条件 <a href="#适用条件-1" id="适用条件-1"></a>

| 要求 | 说明 |
|------|------|
| 系统版本 | macOS 12.0（Monterey）至 macOS 15.0 |
| AppPorts 设置 | 已开启「App Store 应用迁移」 |
| 更新方式 | 手动二次迁移 |

## 签名保护 <a href="#签名保护" id="签名保护"></a>

App Store 应用受系统完整性保护（SIP）影响。AppPorts 在重签名流程中会跳过此类应用：

| 操作 | App Store 应用行为 |
|------|---------------------|
| 手动重签名 | 跳过，SIP 阻止修改 |
| 自动重签名（数据目录迁移后） | 跳过，SIP 阻止修改 |
| 签名备份 | 跳过 |
| 签名恢复 | 跳过 |

## 与其他自更新策略的对比 <a href="#与其他自更新策略的对比" id="与其他自更新策略的对比"></a>

| 应用类型 | 更新策略 | 锁定保护 | 外置存储更新方式 |
|----------|----------|:---:|------|
| App Store 应用（macOS 15.1+） | 原生外置安装 | 否 | App Store 原地增量更新 |
| App Store 应用（macOS <15.1） | Stub Portal | 否 | 二次迁移覆盖 |
| Sparkle / Electron 应用 | Stub Portal | **是** | 锁定后阻止，需迁回本地更新 |
| Chrome / Edge（自定义更新器） | Stub Portal | 否 | 更新到本地，AppPorts 检测后标记「待迁出」 |

{% hint style="warning" %}
**关于锁定保护**

App Store 应用不支持锁定保护（`chflags uchg`）。macOS 15.1+ 由 App Store 原生管理更新，无需锁定；macOS 15.1 以下版本依赖二次迁移覆盖，锁定反而会阻碍 App Store 将更新安装到本地。
{% endhint %}
