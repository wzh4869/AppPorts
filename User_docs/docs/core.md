# 迁移应用

应用迁移移动的是应用本体。聊天记录、项目、模型和缓存等数据可能仍在本机，需要另外使用[数据迁移](/docs/datamigrae/operation)。

## 迁移前 {#prepare}

Clash Verge、Visual Studio Code（包括 Insiders）、Xcode 和 Claude 桌面端的应用本体默认保留在本机。选中它们迁出时，点“取消”即可保留原位置；混合选择时也可以点“仅迁移其他应用”。选择“无视风险迁移”只放行这一次。整文件夹迁移遇到这些应用时，会一起保留所在文件夹。迁回本机无需这项确认。

连接外置存储，在左侧边栏“目标存储”选择外部应用库文件夹，并通过侧栏的“本机磁盘 / 目标存储”确认剩余空间；若目标是 SMB 网络共享或非 APFS 外盘，可从“目标存储”菜单创建或打开 [APFS 应用库映像](/docs/storage-guide#app-library-image) 来完整保留应用元数据。保存工作并完全退出要迁移的应用，确保 AppPorts 从“应用程序”文件夹运行；重要内容先做好备份。系统应用和受保护的位置不适合直接移动，具体限制以 AppPorts 的提示为准。

## 迁移到外置盘 {#move}

1. 在侧栏选择“应用”，在“Mac 本地应用”列表选中应用。需要多选时，按住 Command 再逐个选择。
2. 点击“迁移到外部”，检查目标位置。若应用带有需要确认的自更新器，按使用习惯选择“非锁定迁移”或“锁定迁移”。
3. 若出现同名目标或版本选择，先核对两边内容。不要把不能确认的副本当成垃圾删除。
4. 等待 AppPorts 完成复制、检查和本地入口创建。macOS 27 上下载应用自带的隔离标记（quarantine）不会中断迁移，能否首次打开仍由系统安全策略决定。
5. 从 Finder 或 Dock 启动应用，检查打开文件等常用功能。

[![旧版 AppPorts 的实机列表。Thunderbird 名下是「本地」，TPH 名下是「已链接」。Trae CN 还显示「签名待检查」，可以从这一行检查签名。](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-apps-live-panel-936ddc72877c892e.png?sign=337FzYmLfLNxE05XeK_eS8pW4fZP8Ir-IsHrdZn9PIs%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-apps-live-panel-936ddc72877c892e.png?sign=337FzYmLfLNxE05XeK_eS8pW4fZP8Ir-IsHrdZn9PIs%3D%3A0)

*旧版 AppPorts 的实机列表。Thunderbird 名下是「本地」，TPH 名下是「已链接」。Trae CN 还显示「签名待检查」，可以从这一行检查签名。*

完成后，外部应用库中能看到真实应用，本地保留[启动入口](/docs/glossary#local-portal)。进度接近完成时仍可能在核验或清理，请以最终结果为准。

如果应用不在默认扫描位置，可在“Mac 本地应用”标题栏点击“+”添加扫描目录，例如其他工具管理的安装目录。

任务可在侧栏“任务中心”查看，详情可“加入后台”，稍后再回来检查。暂停与取消都需要等待安全处理；关闭详情不等于取消任务，退出 AppPorts 也不等于让进行中的迁移继续运行。见[任务中心](/docs/datamigrae/operation#task-center)。

迁移前若提示目标盘缺少文件属性能力，请先读[目标盘存不住的应用信息](/docs/storage-capabilities)，再决定是否继续；提示允许继续，不代表应用一定兼容。

## 迁移后如何更新 {#updates}

更新徽章显示迁移后已确认的更新方式。需要选择模式时，只有显示“可用”的应用才推荐非锁定迁移。混合批次中，需要选择模式的每款应用都可用时才推荐。网易云音乐和 WorkBuddy 仍可直接迁移。

[![自更新应用的迁移确认框。示例中的「非锁定迁移」允许应用更新自身，「锁定迁移」保护外部应用原件。](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-update-choice-zh-hans-45724eb40fcfd193.png?sign=CXsmN9zgy6N5e8QpPmkFxUUcJsrEM9clrEOBUAOPW-M%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-update-choice-zh-hans-45724eb40fcfd193.png?sign=CXsmN9zgy6N5e8QpPmkFxUUcJsrEM9clrEOBUAOPW-M%3D%3A0)

*自更新应用的迁移确认框。示例中的「非锁定迁移」允许应用更新自身，「锁定迁移」保护外部应用原件。*

| 情况 | 建议操作 |
| --- | --- |
| 非锁定迁移下应用内更新异常 | 在“设置 → 后台代理”保持开启“应用更新守护”：已适配的 ShipIt 更新失败时，守护会校验缓存新版并尝试完成安装，结果写入任务中心；失败项可在任务详情点击“回退更新”恢复已核验旧版，或迁回本机更新。 |
| 锁定迁移阻止了应用内更新 | 先退出应用，通过 AppPorts 迁回本机更新后再迁出；改为非锁定迁移或迁回本机时，AppPorts 会一并清除关联应用缓存上的保护锁。 |
| 更新程序把新版重新装在本机 | 刷新列表；出现“待迁出”时，核对版本并迁出本地新版。 |
| App Store 管理的外置应用（macOS 15.1+） | 结合 App Store 的外置安装设置使用；AppPorts 可迁移任意大小（含小于 1 GB）的 App Store 应用。 |
| 较早系统上的 App Store 应用 | 在设置中确认是否允许迁移；更新后可能需要再次将本地新版迁出。 |

macOS 15.1 及以上可在 App Store 设置中开启“下载并安装大型 App 到独立存储盘”，并选择与 AppPorts 相同的外置盘。App Store 自身仅对新下载大于 1 GB 的大型应用使用这项设置并直接管理更新；**AppPorts 迁移不受 1 GB 限制，小于 1 GB 的 App Store 应用也能迁入该盘的 `Applications` 目录**。主界面的配置引导可选择“不再提醒”，之后仍能在[设置与权限](/docs/settings#app-store)查看状态和打开 App Store 设置。

“应用更新守护”目前仅接手明确失败且缓存经签名校验通过的 ShipIt 更新，不保证覆盖所有更新框架或全部 ShipIt 变体；详见[更新保护与更新守护](/docs/migration-strategy/portal#updates)。

**用 Homebrew 更新。** 如果应用由默认安装位置的 Homebrew 管理，cask 安装的是单个标准 `.app`，使用非锁定迁移并保留本地启动壳后，接上原盘，照常运行 `brew upgrade`。新版直接装到外盘，原入口可以打开新版，升级时可以退出 AppPorts。已经迁出的应用，在原盘在线时打开 AppPorts 并刷新应用列表即可补登记。迁回后，Homebrew 会继续在原本的本机目录升级。

外盘断开时，该应用的升级会报错；接回原盘后重新运行同一条命令。文件级备份请排除卷根目录的 `.appports-brew`。如果同名备份盘连这个隐藏目录和应用都完整复制了，Homebrew 可能更新备份盘，并把原盘上仍是旧版的应用记为已升级。

## 想迁回或恢复入口 {#restore-links}

- 把真实应用搬回内置盘：使用“迁移回本地”。
- 应用仍在外置盘，只缺本地入口：使用“链接回本地”。
- 只移除本地入口：在本地列表点击应用行右侧的 `…`（“更多操作”）或右键菜单，选择“删除本地入口”。

三种操作的区别和完整步骤见[还原、接回与解除链接](/docs/restore)。如果应用无法打开，先检查外置盘和[状态提示](/docs/badges)，再按[问题排查](/docs/faq#launch)处理。

## 列表、大小缓存与重复搜索结果 {#search-cache}

应用页顶部的“全部 / 已链接 / 未链接”只筛选列表，不会还原或删除应用；切换筛选后，被隐藏的已选项不会继续参与批量操作。本地与外部应用列表均可按名称或大小排序。重新打开 AppPorts 时，两栏会立即恢复上次完成扫描的应用清单、排序方式与只读状态徽章，并在后台静默核对与刷新；如果关闭期间有应用被移走，会在本轮扫描结束后从列表移除；切换目标盘或扫描目录后则会按当前扫描逐批显示。应用与工具目录可显示“上次缓存时间”；磁盘内容已变化或大小看起来过时时，点击侧栏底部的“刷新缓存”重新计算，不要把旧缓存当成当前精确占用。

[![在「Mac 本地应用」列表点击「大小」，比较示例应用的占用，再点击「名称」恢复按名称排列。](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-sort-app-list-zh-hans-c70875d99360d98e.gif?sign=VksxUK9cJL1IvN8tKuc1-Y8gzv99Rsko9t8f3GzOeks%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-sort-app-list-zh-hans-c70875d99360d98e.gif?sign=VksxUK9cJL1IvN8tKuc1-Y8gzv99Rsko9t8f3GzOeks%3D%3A0)

*在「Mac 本地应用」列表点击「大小」，比较示例应用的占用，再点击「名称」恢复按名称排列。*

「外部应用库」标题旁的大小是当前搜索和筛选结果中应用本体的合计。例如，从「全部」切换到「已链接」后，大小只汇总当前显示的已链接应用，后台计算完成时会自动更新。统计采用应用包的逻辑文件大小，适合比较列表中的应用大小；外置盘实际剩余空间请看侧栏「目标存储」。

Spotlight 同时显示本地入口和外盘应用时，可打开“排除外盘应用索引”查看检查结果，再选择处理未完成项。适用的普通独立应用会移入外盘专用的 `AppPorts.noindex` 应用库，本地入口仍可使用；操作涉及真实应用位置，不只是隐藏一条搜索结果。套件目录、App Store 与 iOS 应用暂不自动处理，冲突和失败会单独显示。此操作不排除整块磁盘，外盘文档和照片的搜索不受影响；系统索引刷新仍可能需要等待。
