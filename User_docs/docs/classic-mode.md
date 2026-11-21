# 经典模式

“经典数据迁移模式”保留了较早版本使用符号链接处理容器数据的方式。它默认关闭，主要供仍依赖旧迁移的用户理解和处理现状。

## 开启后改变什么 {#changes}

开启后，适用的容器项目可以提供旧式链接迁移及相关链接管理操作。具体目录仍需通过保护与冲突检查，不会因为打开开关就全部可迁移。

当前版本中，**迁移和重签名是分开的操作**。开启经典模式不等于同意自动重签，也不恢复旧版“迁移后重签名”的流程。手动重签的用途和限制见[设置与权限](/docs/settings#manual-signing)。

## 为什么不作为默认方式 {#why}

容器访问受系统限制，符号链接指向容器外部后，应用可能读不到数据。过去用重签名改变应用身份的做法，还可能影响沙盒、钥匙串或应用组权限；在已测试的 macOS 27 环境中，部分应用因此无法正常启动。

这并不是所有应用都会失败的保证，也不是“只要重新签一次就能修好”。默认推荐对符合条件的数据使用[挂载迁移](/docs/datamigrae/baseinfo#mount)，保留真实应用签名。

## 怎样查看和关闭 {#settings}

在主窗口打开“设置”，找到“经典数据迁移模式（不推荐）”。开启前需要阅读确认说明；不需要旧式迁移时保持关闭即可。

[![「经典数据迁移模式」位于设置页。图中开关已关闭，下方的「查看完整说明」可打开使用条件。](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-classic-zh-hans-69c0e6d5566a2036.png?sign=kJyraHzRimR-FuJyCY_m2nQ2EQrHR8o_gVSxIfFrNs0%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-classic-zh-hans-69c0e6d5566a2036.png?sign=kJyraHzRimR-FuJyCY_m2nQ2EQrHR8o_gVSxIfFrNs0%3D%3A0)

*「经典数据迁移模式」位于设置页。图中开关已关闭，下方的「查看完整说明」可打开使用条件。*

**关闭开关不会自动还原已存在的链接，也不会恢复过去改过的签名。** 原有数据需要按实际状态单独处理，不能只看开关位置判断已经完成升级。

## 已经使用旧方式怎么办 {#transition}

1. 连接原外置盘，退出关联应用，保留现有数据和备份。
2. 对旧符号链接迁移的容器数据使用“还原”，让数据回到原位置。
3. 若应用曾被替换签名，按[macOS 27 升级与修复](/docs/macos-27)处理。
4. 检查应用与数据正常后，需要外置存放时再选择挂载迁移。

没有合适 APFS 存储时，可以让容器数据继续留在本机。不要只为绕过格式要求而开启经典模式。

相关内容：[还原与接回](/docs/restore) · [符号链接实验](/docs/blog/why-mount-and-apfs#symlink-experiment) · [经典模式词条](/docs/glossary#classic-mode)

旧版开关与自动签名的详细变化保存在[历史功能归档](/docs/archive/data-signing)。
