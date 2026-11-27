# 快速开始

准备一块连接稳定、空间足够的外置盘，以及运行 macOS 12 或更高版本的 Mac。本页带你完成安装和第一次应用迁移；如果你只想移动聊天记录、缓存或模型等数据，可以在准备完成后转到[迁移数据](/docs/datamigrae/operation)。

## 下载并安装 {#install}

1. 从[AppPorts 下载页](https://file.shimoko.com/AppPorts)或 [GitHub Releases](https://github.com/wzh4869/AppPorts/releases) 获取安装包，把 AppPorts 拖入 Mac 的“应用程序”文件夹；也可以使用 Homebrew 安装：

```sh
brew install --cask wzh4869/tap/appports
```

通过 Homebrew 升级或卸载的命令见 [AppPorts 的 Homebrew 安装说明](https://github.com/wzh4869/homebrew-tap#readme)。

2. 从“应用程序”打开 AppPorts，按引导完成上手：全新用户会依次看到“核心能力概览 → 边界与共识 → 准备情况”3 步引导；从旧版本升级的老用户会看到一次单屏的“关于 AppPorts 的边界与共识”确认，不会重置已有权限、已迁移应用和记录，之后也可随时在设置顶部点击“边界与共识”重看。发起新迁移、操作磁盘映像和打开权限引导前，AppPorts 会检查自身是否位于“应用程序”文件夹；不要从安装镜像或临时目录长期运行。

[![打开 DMG，把左侧的 AppPorts 图标拖到右侧的 Applications 文件夹上，然后松开。](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-install-drag-5d967c0d07f9edcb.gif?sign=2fap3x95UNN19dzzLIznjNIjszdqpbwLfVZIy8H99A8%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-install-drag-5d967c0d07f9edcb.gif?sign=2fap3x95UNN19dzzLIznjNIjszdqpbwLfVZIy8H99A8%3D%3A0)

*打开 DMG，把左侧的 AppPorts 图标拖到右侧的 Applications 文件夹上，然后松开。*

## 准备权限与外置盘 {#permissions}

1. 连接外置盘，在左侧边栏“目标存储”选择外部存储文件夹；若目标是 NAS 共享或非 APFS 外盘，也可以从同一菜单创建或打开 [APFS 应用库映像](/docs/storage-guide#app-library-image)。
2. 点击侧栏底部的设置齿轮（或按 `Command + ,`），查看“准备情况”卡片。按提示点击“打开系统设置”，为 AppPorts 开启“完全磁盘访问权限”，系统需要时再授予“App 管理”权限；如果系统列表中找不到 AppPorts，可直接把屏幕上的引导图标拖入系统设置列表。
3. 按提示重新打开 AppPorts，可在“准备情况”标题右侧点击“检查”核对状态。

[![从侧栏底部进入设置，点击「检查」刷新准备情况。](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-readiness-pointer-4e6a0bbfbc33714f.gif?sign=QeBq7i0li3XCK2-rJQ89siGLCGWWhMHhGhMYNX8Apyo%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-readiness-pointer-4e6a0bbfbc33714f.gif?sign=QeBq7i0li3XCK2-rJQ89siGLCGWWhMHhGhMYNX8Apyo%3D%3A0)

*从侧栏底部进入设置，点击「检查」刷新准备情况。*

**只有容器数据的挂载迁移要求 APFS 存储。** 普通应用和普通文件夹按各自条件检查，不必为了第一次应用迁移就抹掉现有磁盘。格式不符合要求时，先阅读[外置盘准备方法](/docs/storage-guide#apfs)。

## 完成第一次迁移 {#first-move}

1. 选择一个你熟悉的应用，保存工作并完全退出它。
2. 在侧栏打开“应用”，在“Mac 本地应用”列表中选中应用，点击“迁移到外部”。
3. 阅读目标位置、更新方式或冲突提示，确认是你要移动的内容后继续。
4. 等待复制、检查和收尾全部完成。过程中保持外置盘连接，不要重新打开该应用。
5. 从 Finder 或 Dock 打开迁移后的应用，检查主要功能是否正常。

完成后，真实应用存放在外置存储，本地保留启动入口；列表会显示相应的[状态徽章](/docs/badges)。遇到同名目标、权限不足或中断时，先按提示处理，不要自行删除两边的数据。

## 下一步 {#next}

- 应用能正常打开：继续了解[迁移后的更新方式](/docs/core#updates)。
- 想移动应用产生的数据：阅读[迁移数据](/docs/datamigrae/operation)。
- 想恢复本地存放：阅读[还原与接回](/docs/restore)。
- 操作没完成或应用打不开：从[常见问题与排查](/docs/faq)查找对应现象。

迁移会改变数据的存放位置，不会替代备份。日常使用前先连接外置盘，断开前退出使用它的应用并正常弹出磁盘。
