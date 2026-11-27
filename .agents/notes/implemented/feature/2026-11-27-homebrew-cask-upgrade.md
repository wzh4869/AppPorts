# Agent Note: Homebrew 直接升级外盘应用

Status: implemented

## Problem

标准 cask 的旧版本链接和安装配置都记着本机目录。普通应用迁移后，本机同名的 .app 已经是启动壳。Homebrew 若继续按旧记录升级，就会把新版装到入口位置，外盘上的应用仍是旧版。只改 cask 的 appdir 会使它在备份旧版本时遇到路径冲突。

## Decision

AppPorts 在应用位置切换已提交、旧副本仍可恢复时，逐个处理能唯一对应本机启动壳的 cask。它读取默认 Homebrew 前缀内的已安装收据、当前版本的 JSON 定义和暂存链接。只处理未锁定的标准单应用，允许平级文件改名。文件夹迁移、包安装器和需要执行 Ruby 才能识别的定义跳过。原盘在线时，应用列表扫描用已有迁移记录补登记，同一批扫描共用一次 cask 清单。

AppPorts 先在自己的应用支持目录保存原本机路径、原 appdir 是否显式、外盘 UUID、cask 所在 Caskroom 的身份及应用标识。外盘根目录的 `.appports-brew` 内按卷 UUID 和相对目录名的摘要保存相对软链接。同卷同目录的 cask 共用该入口。当前版本的暂存链接和此 cask 的 `explicit.appdir` 一起指向该入口。原配置中的其他字段保留。写到一半时，已有收据足以识别中间状态并重试；遇到第三方改写的位置则保留现场。之后由 Homebrew 自身决定哪些 cask 需要更新、备份旧版并安装新版。

正常迁回恢复本机目录、旧链接使用的路径拼写以及原 appdir 的继承状态。将外盘应用转换到 AppPorts.noindex 时，登记跟随已提交的位置切换。只有原卷在线、原 cask 与应用本体都已移除、遗留入口的签名、标识和目标路径均吻合时，AppPorts 才将遗留启动壳移入废纸篓。仍有其他 cask 使用的隐藏链接继续保留。

## Existing-note audit

本项扩展[持久化应用迁移](../architecture/2026-10-10-verified-transfer-lifecycle.md)的切换后收尾。现有 ShipIt 缓存恢复、更新保护、签名备份和外盘弹出笔记分别约束应用自更新、文件锁、签名与卷挂载，没有管理 Homebrew 安装收据。现有决策树中没有同职责的提案或已否决记录。

## Alternatives considered

- 直接将 cask 指向可见的外盘应用目录，省去一个软链接。隔离测试中，同名的另一张盘在相同位置有另一个应用时，Homebrew 会覆盖它并登记升级成功。
- 升级后再把本机新版迁回外盘，能让 AppPorts 在最终写入前重新确认磁盘，但需要本机临时容纳新版、重建入口，还依赖 AppPorts 再次运行。
- 由 Homebrew 在写入前核验实时卷 UUID，可以识别完整克隆盘。现有 Homebrew 没有这项检查，本功能选择与已安装的 Homebrew 直接配合。

## Consequences

用户继续使用普通的 `brew upgrade`。外盘应用与本机应用可在同一批次各自升级；外盘断开时，该 cask 报错，接回后可重新执行。该集成依赖 Homebrew 的已安装元数据格式，将来格式变化时需要重新验证。隐藏入口能区分通常的同名磁盘，但同名备份若复制了隐藏目录和应用，Homebrew 仍可能更新备份盘并把原盘登记为已升级。三语使用说明提示在文件级备份中排除卷根的 `.appports-brew`。

## Verification

常规单测覆盖登记中断、原配置继承、其他设置保留、断盘后丢失的暂存链接、冲突写入与不支持的 cask 结构。macOS 隔离联调用真实 Homebrew 7、私有 Caskroom 和同名不同 UUID 的 APFS 映像执行普通升级、入口启动、卸载与迁回。这个实验不覆盖真实 USB 拔插、其他 Homebrew 版本或 Gatekeeper 的首次启动体验。

2026-11-27 的专项验证通过 197 个 XCTest 用例和 6 个 Swift Testing 用例，Release clean build 通过。联调包含人为阻断登记后的同一事务重试、两次混合升级后的入口启动、离线批量升级、接错盘与重试、旧迁移补登记、迁回自定义本机目录及转入 AppPorts.noindex 后再次升级。
