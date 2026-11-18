# AppPorts 隐私政策 | Privacy Policy

[简体中文](#appports-隐私政策) | [English](#appports-privacy-policy)

---

# AppPorts 隐私政策

**更新日期：** 2026 年 11 月 18 日
**生效日期：** 2026 年 11 月 18 日
**适用版本：** AppPorts 1.8.1 及后续版本

AppPorts（以下称“本软件”）是一款运行于 macOS 平台的应用程序迁移工具。本隐私政策（以下称“本政策”）阐释我们如何收集、使用、共享与保护您的个人信息，以及您就此享有的权利。

本政策适用于本软件，以及我们的官方网站（appports.shimoko.com）与用户文档站（docs-appports.shimoko.com）。除本政策外，我们在需要读取您信息的各项功能中，还会以相应的页面提示向您说明该功能的信息处理规则。

请您在使用本软件或访问前述站点前，仔细阅读并充分理解本政策全部内容。您开始使用本软件或访问前述站点，即表示您已阅读、理解并同意本政策。本政策不适用于第三方如何定义或使用您的个人信息，我们建议您在与其互动之前先行阅读其隐私政策。

## 第一条  定义

本政策中下列用语的含义为：

- **个人信息**：指以电子或者其他方式记录的与已识别或者可识别的自然人有关的各种信息，既包括可直接识别您身份的信息（如姓名），也包括不能直接识别、但可通过合理推断间接识别您身份的信息（如设备序列号），不包括匿名化处理后的信息。
- **汇总数据**：指经统计处理后无法识别特定自然人的数据。就本政策而言，汇总数据不属于个人信息。
- **个人信息处理**：指个人信息的收集、存储、使用、加工、传输、提供、公开、删除等行为。
- **您**：指本软件的最终用户以及前述站点的访问者。
- **我们**：指本软件的开发者与运营者。

## 第二条  适用范围

本政策适用于您通过本软件、官方网站与用户文档站与我们发生的各项互动。官方网站与用户文档站均为静态站点，不设用户账号体系，亦不提供用户生成内容功能。

本政策不适用于前述站点所链接的第三方服务，该等第三方服务由其各自的隐私政策约束。

## 第三条  我们的承诺

我们坚信并尊重基本隐私权，并认为这些权利不应因您所在的国家或地区而有所不同。

基于上述理念，我们不设计任何以牺牲隐私为代价的功能：本软件的核心功能完全在您的设备本地完成，我们不设账号体系，不采集使用行为，不进行个性化推荐。若某项功能的实现确需读取您的信息，我们会在本政策或该功能的页面中明确告知其范围与目的。

## 第四条  我们收集与使用的个人信息

我们不收集、不使用、不对外提供您的任何个人信息，亦不在服务器端保留任何与您相关的数据。具体而言：

- 本软件不设账号体系，不提供注册、登录功能，不收集手机号码、电子邮箱、姓名等身份信息；
- 本软件不集成任何统计分析、行为追踪、A/B 测试或崩溃收集类软件开发工具包；
- 本软件不集成任何广告或消息推送类软件开发工具包，不进行个性化广告投放；
- 本软件不生成、不读取任何设备标识符（如 IDFA、IDFV、硬件序列号、硬件 UUID）；
- 本软件不申请、不获取通讯录、日历、提醒事项、照片、麦克风、摄像头、定位、蓝牙、健康等任何系统权限；
- 本软件仅在您选择保存加密 APFS 数据卷密码时读写本机登录钥匙串中的对应项目（`com.appports.encrypted-apfs-volume`），不读取其他应用的密码；
- 本软件不为统计分析或广告目的设置、读取 Cookie。

## 第五条  本软件在本机读取的信息

为实现“将应用程序及其数据迁移至外部存储介质”这一核心功能，本软件需在您的设备本地读取下列信息。上述读取行为均在本机完成，不构成向任何第三方提供个人信息：

- 应用程序目录（如 `/Applications`）中的应用程序包、图标及其代码签名信息；
- `~/Library` 目录下与应用程序相关的数据目录，用于识别可迁移的数据并计算其占用空间；
- 您自行添加的自定义扫描路径；
- 您指定的外部存储介质路径或 APFS 应用库映像路径，用作迁移目标位置及链接状态校验；
- 已连接存储卷的标识、连接类型、可写状态和剩余空间，用于核对迁移位置，并在需要保存签名原包时自动选择合适外盘；
- 当前正在运行的应用程序列表，用于在迁移前确认目标应用程序未处于运行状态，以避免数据损坏；
- 系统 App Store 外置安装偏好（`com.apple.appstored` 中的目标卷设置，仅只读核对是否与所选外置存储一致），以及已迁移应用在本机产生的 ShipIt 更新状态与日志（仅在启用“应用更新守护”时用于识别明确失败的更新并执行恢复或清理重试记录）；
- 设备基本运行信息，包括 macOS 版本、处理器核心数、物理内存容量以及外部存储介质读写速度，仅用于生成本地日志与迁移性能报告。

## 第六条  网络访问与信息接收方

本软件仅在下列情形下发起网络请求，且请求内容不包含您的任何个人信息，亦不包含账号标识、设备标识、文件路径及文件名称：

- **版本检查**：本软件在启动时进行一次静默版本检查，或依您的操作发起检查，请求地址为用户文档站的 `docs-appports.shimoko.com/latest.json`（及官方网站对应发布信息），并按需要查询 GitHub 平台上的版本信息（`api.github.com`），在该接口不可用时回退至 `github.com` 提供的 `releases.atom` 地址；
- **应用内更新下载**：当您在更新提示中主动点击“国内更新”或“GitHub 更新”时，本软件会从官方下载源（`file.shimoko.com`）或对应 GitHub Release 附件地址下载新版本安装包，并在本机完成 SHA-256 哈希与代码签名核验；
- **信息展示**：在您打开“关于 AppPorts”窗口时，本软件请求 GitHub 平台的贡献者名单，以及用户文档站的赞助者名单（`docs-appports.shimoko.com/sponsors.json`）。

上述请求仅携带固定的 User-Agent 标识（`AppPorts`、`AppPorts-UpdateChecker` 或 `AppPorts-Updater`）。基于 HTTP 协议的固有属性，接收方服务器可获取您的 IP 地址与请求时间。前述接收方为 GitHub 平台及本项目官方网站、下载源与用户文档站的服务器，其个人信息处理行为分别适用其各自的隐私政策。

打开官方网站、用户文档、代码仓库、赞助页等外部链接，或通过网页下载链接手动获取安装包时，不由本软件自行实施，而是交由您的默认浏览器完成。

## 第七条  信息的本地存储

本软件在您的设备本地存储下列文件与配置，相关内容不涉及个人信息的对外提供：

- `~/Library/Application Support/AppPorts/AppPorts_Log.txt`：操作日志与诊断信息；
- 本机登录钥匙串：仅在您选择保存时存储对应加密 APFS 数据卷的密码（`com.appports.encrypted-apfs-volume`），不同步；密码不写入日志或迁移记录，未保存时仅在进程内临时使用；
- 应用和工具目录大小缓存、应用搜索位置记录（`app-search-records.json`）：用于显示大小、缓存时间及维护应用库和本地入口，不上传文件清单；
- `migration-task-history.json`：任务名称、类别、相关路径、时间和展示结果；仅用于任务历史展示，不是自动重新执行的队列；
- `disk-ejection-pauses.plist` 与 `launch-locks`：分别保存主动弹盘、卸载应用库映像或卸载单个数据卷后的自动挂载暂停信息，以及供本机进程协调迁移期间启动保护的锁文件，不会上传；
- `~/Library/Application Support/AppPorts/contributors-cache.json` 与 `sponsors-cache.json`：贡献者与赞助者名单缓存，用于减少重复网络请求及离线展示；
- `~/Library/Application Support/AppPorts/` 下的迁移、挂载、签名与恢复记录（含日志、事务 journal 与 `shipit-recovery/` 下的更新恢复收据、回退意图与单次更新状态文件）：保存应用身份、相关路径、卷标识及操作状态，用于接回数据、恢复签名、同步后台更新守护结果和继续未完成的操作；
- `~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist` 与 `~/Library/LaunchAgents/com.shimoko.AppPorts.update-guardian.plist`：仅当您启用对应“后台代理”（容器数据与映像自动挂载或应用更新守护）时按需写入的用户级启动代理定义，用于在登录或外置存储挂载事件发生时于本机执行自动恢复，可随时在设置中关闭移除；
- 外盘根目录的 `AppPorts Backups` 文件夹：自 1.9.1 build 31 起，保存手动重签前经核对的官方应用原包，内附 `README.txt`；这些原包用于恢复应用内容和签名，不是聊天记录、文档等个人数据的备份；
- `~/Library/Preferences` 目录下的偏好设置文件：界面语言、外部存储路径、应用库映像位置记录（SMB 共享地址不含密码，或底层卷与映像内 APFS 卷标识）、自定义扫描路径、后台代理开关、引导提醒状态及各项功能开关。

重签过程中还会在真实应用旁建立临时工作副本；仍有恢复价值的旧内盘原包，会在满足条件并完成外盘复制核验后迁出。原包、索引和上述操作记录均保存在本地存储设备，不会因保存或自动维护而上传。

您可以删除缓存、日志、配置和启动代理；在删除迁移或恢复记录前，请先通过本软件完成相关还原与收尾，避免丢失数据接回或签名恢复所需的信息。卸载本软件不会自动还原已迁移的数据，也不会自动删除外盘上的应用、数据或签名原包。

## 第八条  诊断包

“导出诊断包”功能仅在您主动点击后执行，并且：

- 导出文件的保存位置由您在系统保存面板中自行选择；
- 导出前，本软件会将日志中的用户名替换为 `~`，将 `/Users/<用户名>` 替换为 `/Users/<redacted-user>`，并对您的外部存储介质名称作脱敏处理；
- 本软件不会自动上传该文件，亦不会将其提供给任何第三方。是否将其提供给我们，完全由您自行决定。

## 第九条  系统权限

为实现上述功能，本软件可能涉及下列系统权限：

- **完全磁盘访问权限**：用于读写 `/Applications` 及 `~/Library` 下的相关目录。该权限需由您在“系统设置 - 隐私与安全性”中手动开启，本软件无法自行申请，亦无法绕过该权限限制。
- **App 管理权限**：在 macOS 系统机制要求更新或修改受保护应用包内容时触发，用于在迁移、创建本地入口、恢复或清理旧应用副本时完成应用目录写入。您可在“系统设置 - 隐私与安全性 - App 管理”中管理授权。
- **自动化权限（Apple 事件）**：在特定场景需要通过 Finder 协助移动或清理应用，或请求将外置磁盘弹出时，macOS 将向您征求同意。您有权拒绝，并可随时在“系统设置 - 隐私与安全性 - 自动化”中关闭该权限。
- **管理员权限**：在对归属 root 用户安装的应用执行移动、恢复、重签或修复所有权，在手工重试时清理归属 root 的保留数据旧副本，或系统要求以管理员身份完成特定磁盘挂载/卸载操作时触发。您输入的管理员密码由 macOS 系统对话框直接提交至操作系统，本软件不读取、不记录、不存储该密码。

本软件未申请通讯录、日历、照片、麦克风、摄像头、定位、蓝牙等任何权限，仅在您选择保存加密数据卷密码时使用本机登录钥匙串中的对应项目。

本软件未启用 App Sandbox（因需跨磁盘读写应用程序与数据目录），但已启用 Hardened Runtime。发行版本未经 Apple 公证，首次运行时您可能需要在“系统设置 - 隐私与安全性”中手动允许。

## 第十条  Cookie 与同类技术

我们的官方网站（appports.shimoko.com）与用户文档站（docs-appports.shimoko.com）均为静态站点，不使用 Cookie 进行统计分析，不包含第三方广告或社交插件，也不设置跨站跟踪像素；开源用户文档站代码本身亦未内嵌第三方统计脚本。

如官方网站使用开源、无 Cookie 的页面汇总统计工具（如 Umami）来了解页面访问概况并改进内容，其处理规则如下：

- 不使用 Cookie，不采集可识别您个人身份的信息，不进行跨站追踪；
- 不存储您的原始 IP 地址，该地址仅在请求发生时用于判断粗略地区并对访问去重；
- 仅记录页面访问量、来源站点、浏览器与操作系统类型、粗略地区等汇总数据；
- 您可以随时通过浏览器的内容拦截扩展或网络过滤器屏蔽统计请求，此举不影响页面的正常访问与阅读。

若您所在国家或地区的法律将 IP 地址或类似标识视为个人信息，我们将以同等标准对待此类标识。

站点托管服务商可能基于运维与安全防护的需要保留常规访问日志。

## 第十一条  赞助者信息的公开

当您通过赞助二维码支持本项目，并在留言中填写昵称时，昵称将公开显示于用户文档站的赞助页及本软件“关于 AppPorts”窗口的赞助者区块。个人链接为选填，未提供时仅展示昵称；赞助金额仅在网站赞助页展示。

上述情形是本项目中唯一涉及个人信息公开的场景，且以您的自愿提供为前提。若您不希望昵称或链接被公开，可在赞助时不作填写，或依第十八条载明的方式要求更正、删除。

## 第十二条  第三方平台

在下列情形中，相关信息的处理由第三方平台独立进行，适用其各自的隐私政策，我们不对第三方的信息处理行为负责：

- 您通过 GitHub 平台提交 Issue 或 Pull Request 时，相关信息由 GitHub 处理；
- 您通过 Bilibili、微信、支付宝等平台进行赞助时，支付相关信息由该等平台处理，我们不接触您的支付账号信息；
- 您通过本软件或前述站点打开第三方链接时，该第三方站点可能自行收集您的信息。

## 第十三条  个人信息的跨境传输

本软件不在服务器端收集或存储您的个人信息，因此不涉及由我们发起的个人信息出境活动。

当您通过 GitHub、Bilibili 等平台与我们互动时，相关信息可能由该等平台传输至其所在国家或地区的服务器，该等传输与处理由其依其隐私政策独立完成。

## 第十四条  未成年人保护

本软件不面向未成年人设计，不会主动收集未成年人的个人信息。若您是未成年人，请在监护人的陪同下阅读本政策，并在取得监护人同意后使用本软件。

## 第十五条  信息安全

鉴于本软件不在服务器端收集或存储您的个人信息，不存在因服务器数据泄露而导致您的个人信息外泄的风险。本软件在本机读取与写入的文件，其安全性依赖于您的设备与操作系统自身的安全防护措施，我们建议您妥善保管设备并保持系统更新。

## 第十六条  您的隐私权

我们尊重您获知、访问、更正、传输、限制处理与删除个人信息的能力。由于我们不收集、不存储您的个人信息，我们不掌握可供查询、更正或删除的个人信息；但我们保障您就本政策与我们沟通的权利，并承诺不因您行使上述权利而对您作任何区别对待。

若我们在任何情形下需以您的同意作为个人信息处理的合法性基础，您有权随时撤回该同意，且撤回同意不影响撤回前基于您的同意已进行的处理活动的效力。

您可以通过下列方式行使您的权利：

- 按第七条说明管理或删除本地缓存、日志、配置、启动代理及恢复材料；删除前请先完成仍由本软件管理的迁移还原，卸载软件不会自动删除外盘上的应用、数据或签名原包；
- 就已公开的赞助者信息，随时依第十八条载明的方式要求更正或删除；
- 若您认为我们的个人信息处理行为损害了您的合法权益，您有权向有关监管部门投诉、举报。

## 第十七条  政策更新

我们可能适时修订本政策。修订后，本页面顶部的“更新日期”与“生效日期”将同步更新。涉及您权利实质变更的重大修订，我们将在版本更新日志及 GitHub Release 说明中予以提示。

本政策以简体中文版本为准，其他语言译本仅供参考。

## 第十八条  联系方式

有关本政策或个人信息保护的任何疑问、意见或投诉，可通过下列方式与我们联系：

**电子邮箱：a@shimoko.com**

我们将在收到您的请求后十五个工作日内予以答复。

---

# AppPorts Privacy Policy

**Last updated:** November 18, 2026
**Effective date:** November 18, 2026
**Applies to:** AppPorts 1.8.1 and later

AppPorts (the "Software") is an application migration tool for macOS. This Privacy Policy (the "Policy") explains how we collect, use, share, and protect your personal information, and the rights you have in that regard.

This Policy applies to the Software and to our official website (appports.shimoko.com) and documentation site (docs-appports.shimoko.com). In addition to this Policy, for each feature that needs to read your information we also explain that feature's information-handling rules in the relevant interface.

Please read this Policy in full and make sure you understand it before using the Software or visiting those sites. By using the Software or visiting those sites, you confirm that you have read, understood, and accepted this Policy. This Policy does not govern how third parties define or use your personal information; review their policies before interacting with them.

## 1. Definitions

For the purposes of this Policy:

- **"Personal information"** means any information relating to an identified or identifiable natural person that is recorded electronically or otherwise. It includes information that identifies you directly, such as your name, and information that does not identify you directly but can reasonably be inferred to do so, such as a device serial number. It excludes anonymised information.
- **"Aggregate data"** means data that, after statistical processing, cannot identify a specific natural person. For the purposes of this Policy, aggregate data is not personal information.
- **"Processing"** means any operation performed on personal information, including collection, storage, use, adaptation, transmission, provision, disclosure, and deletion.
- **"You"** means the end user of the Software and a visitor to the sites described above.
- **"We"** means the developer and operator of the Software.

## 2. Scope

This Policy covers your interactions with us through the Software, official website, and documentation site. Both sites are static, with no user accounts and no user-generated content features.

This Policy does not apply to third-party services linked from these sites; such services are governed by their own privacy policies.

## 3. Our Commitment

We believe in and respect fundamental privacy rights, regardless of your country or region.

Consistent with that principle, we do not design features at the expense of your privacy. Core functionality runs entirely on your device: there is no account system, no usage tracking, and no personalised recommendations. Where a feature genuinely needs to read your information, we state its scope and purpose in this Policy or in the relevant interface.

## 4. Personal Information We Collect and Use

We do not collect, use, or disclose any of your personal information, and we retain no data about you on any server. Specifically:

- The Software has no account registration or sign-in and collects no identifiers such as phone numbers, email addresses, or names;
- The Software includes no analytics, behavioural tracking, A/B testing, or crash-reporting SDKs;
- The Software includes no advertising or push-notification SDKs and serves no personalised advertising;
- The Software neither generates nor reads any device identifier (such as IDFA, IDFV, hardware serial number, or hardware UUID);
- The Software requests no Contacts, Calendar, Reminders, Photos, microphone, camera, location, Bluetooth, or health permissions;
- The Software reads or writes only its own encrypted APFS data-volume password items (`com.appports.encrypted-apfs-volume`) in your local login Keychain when you choose to save them, and never reads other applications' passwords;
- The Software sets and reads no cookies for analytics or advertising purposes.

## 5. Information Read Locally

To migrate applications and their data to external storage, the Software reads the following information on your device. All of this reading takes place locally and does not disclose personal information to third parties:

- Application bundles, icons, and code-signature information in application directories such as `/Applications`;
- Application-related data directories under `~/Library`, used to identify migratable data and measure sizes;
- Custom scan paths you add;
- External-storage paths or APFS app library disk-image paths you select, for migration targets and link-state verification;
- Connected volumes' identifiers, connection types, writability, and free space, to verify migration locations and select a suitable external drive when saving signature originals;
- Currently running applications, to check that a target app is not running before migration and avoid data corruption;
- System App Store external-installation preferences (`PreferredVolume` in `com.apple.appstored`, read-only to check consistency with the selected external drive) and local ShipIt update status and logs produced by migrated applications (used only when Application update guardian is enabled to identify explicitly failed updates and perform recovery or clean up retry state);
- Basic device operational information, including the macOS version, processor core count, physical memory, and external drive read/write speed, used only to generate local logs and migration performance reports.

## 6. Network Access and Recipients

The Software makes network requests only in the following cases, and request contents exclude personal information, account identifiers, device identifiers, file paths, and file names:

- **Version checks**: one silent version check at launch or a check you initiate requests `docs-appports.shimoko.com/latest.json` (and corresponding official release metadata), and queries GitHub version information (`api.github.com`) when needed, falling back to `github.com`'s `releases.atom` feed if that API is unavailable;
- **In-app update downloads**: when you explicitly choose Update via China mirror or Update via GitHub in an update prompt, the Software downloads the release package from the official download mirror (`file.shimoko.com`) or the corresponding GitHub Release asset URL and verifies its SHA-256 hash and code signature locally;
- **Displayed information**: when you open "About AppPorts", the Software requests the contributor list from GitHub and the sponsor list from the documentation site (`docs-appports.shimoko.com/sponsors.json`).

These requests carry only a fixed User-Agent string (`AppPorts`, `AppPorts-UpdateChecker`, or `AppPorts-Updater`). As an inherent property of HTTP, recipient servers can obtain your IP address and the time of the request. Recipients include GitHub and the servers of this project's official website, download mirror, and documentation site, each governed by its own privacy policy.

Opening the website, documentation, repository, sponsor page, or other external links, or manually downloading releases through web links, is handled by your default browser rather than performed by the Software itself.

## 7. Local Storage

The Software stores the following files and settings locally on your device. None of this involves disclosing personal information to any third party:

- `~/Library/Application Support/AppPorts/AppPorts_Log.txt`: operation logs and diagnostic information;
- Local login Keychain: passwords for encrypted APFS data volumes (`com.appports.encrypted-apfs-volume`) only when you choose to save them, without syncing; passwords are never written to logs or migration records and otherwise stay only temporarily in memory;
- App and tool-directory size caches and application search-location records (`app-search-records.json`): used to display sizes and cache timestamps and maintain app libraries and local entries; file inventories are never uploaded;
- `migration-task-history.json`: task names, categories, associated paths, times, and display results; display history only, not a queue that automatically repeats operations;
- `disk-ejection-pauses.plist` and `launch-locks`: local mounting-pause state after an explicit physical-disk eject, app library image unmount, or individual data-volume unmount, plus lock files used by local processes to coordinate launch protection during migration; never uploaded;
- `~/Library/Application Support/AppPorts/contributors-cache.json` and `sponsors-cache.json`: cached contributor and sponsor lists to reduce repeated requests and support offline display;
- Migration, mount, signing, and recovery records under `~/Library/Application Support/AppPorts/` (including operation logs, journals, and update recovery receipts, rollback intents, and per-request status files under `shipit-recovery/`): app identity, paths, volume identifiers, and operation states for reconnection, signature restoration, background update-guardian synchronization, and unfinished operations;
- `~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist` and `~/Library/LaunchAgents/com.shimoko.AppPorts.update-guardian.plist`: user LaunchAgent definitions written only when you enable the corresponding background agent (automatic container/image mounting or Application update guardian) to run local recovery on login or storage mount events; disabling an agent in Settings removes it;
- `AppPorts Backups` at a suitable external drive's root: since 1.9.1 build 31, verified official app originals are saved automatically before manual re-signing, with `README.txt`; these restore app bundles and signatures, not personal files such as chat logs or documents;
- Preference files under `~/Library/Preferences`: interface language, external storage path, app library image location records (SMB share address without credentials, or backing volume and internal APFS volume identifiers), custom scan paths, background-agent toggles, guidance dismissal state, and feature switches.

Signing also creates a temporary working copy beside the real app; useful older internal originals move externally after verification passes. Originals, indexes, and operation records stay on local storage devices and are never uploaded.

You may delete caches, logs, preferences, and LaunchAgents at any time. Before deleting migration or recovery records, complete restoration and finalization through the Software so reconnection or signature recovery information is not lost. Uninstalling the Software does not automatically restore migrated data or delete external apps, data, or signature originals.

## 8. Diagnostic Package

The "Export Diagnostics" function runs only when you click it, and:

- you choose the destination file location in the system save panel;
- before export, the Software replaces usernames in the logs with `~`, replaces `/Users/<username>` with `/Users/<redacted-user>`, and redacts the names of your external storage volumes;
- the Software never uploads that file automatically and never provides it to any third party. Whether to share it with us is entirely your decision.

## 9. System Permissions

To provide the functions described above, the Software may involve the following system permissions:

- **Full Disk Access**: used to read and write relevant directories under `/Applications` and `~/Library`. You enable it manually in System Settings → Privacy & Security. The Software cannot grant itself this permission or bypass it.
- **App Management**: prompted by macOS when an operation needs to modify or update protected application bundles while moving apps, creating local portals, restoring bundles, or cleaning up old app copies. Manageable in System Settings → Privacy & Security → App Management.
- **Automation (Apple Events)**: when an operation needs Finder to move or delete an app or to request disk ejection, macOS asks for your consent. You may decline and revoke it at any time in System Settings → Privacy & Security → Automation.
- **Administrator privileges**: triggered when moving, restoring, re-signing, or repairing ownership of root-owned app installations, cleaning up root-owned retained old data copies on manual retry, or when macOS requires administrator authorization for specific disk mount/unmount operations. Your administrator password is submitted by the macOS system dialog directly to macOS; the Software does not read, record, or store it.

The Software requests no Contacts, Calendar, Photos, microphone, camera, location, or Bluetooth permissions, and accesses only its own encrypted data-volume Keychain items when you choose to save them.

App Sandbox is disabled because cross-volume reading and writing of applications and data directories is required; Hardened Runtime is enabled. Release builds are not notarized by Apple, so first launch may require your approval in System Settings → Privacy & Security.

## 10. Cookies and Similar Technologies

Our official website (appports.shimoko.com) and documentation site (docs-appports.shimoko.com) are static sites. They use no cookies for analytics, contain no third-party advertising or social plugins, and set no cross-site tracking pixels; the open-source documentation site repository likewise embeds no third-party analytics or tracking scripts.

Where the official website uses cookie-free aggregate page-view statistics (such as Umami) to understand usage and improve content, it applies these rules:

- no cookies, no personally identifiable information, and no cross-site tracking;
- your raw IP address is not stored — it is used only at request time to infer an approximate region and deduplicate visits;
- only aggregate data is recorded, such as page views, referring site, browser and operating system type, and approximate region;
- you can block analytics requests at any time with a content blocker or network filter without affecting normal browsing or reading.

If local law treats IP addresses or similar identifiers as personal information, we treat them to the same standard.

The hosting provider may retain standard access logs for operations and security purposes.

## 11. Publication of Sponsor Information

If you support the project through the sponsor QR code and provide a nickname in the payment note, that nickname will be published on the documentation site's sponsor page and in the "About AppPorts" window. Providing a personal link is optional; sponsorship amounts are displayed only on the website sponsor page.

This is the only case in this project in which personal information is made public, and it depends on your voluntary provision. If you prefer not to publish a nickname or link, leave those fields blank, or request correction or removal under clause 18.

## 12. Third-Party Platforms

In the following cases, information is handled independently by third-party platforms under their own privacy policies, and we are not responsible for their handling practices:

- when you submit an Issue or Pull Request on GitHub, that information is handled by GitHub;
- when you sponsor the project through platforms such as Bilibili, WeChat, or Alipay, payment details are handled by those platforms, and we never have access to your payment-account details;
- when you open a third-party link from the Software or from those sites, that third party may collect information on its own.

## 13. Cross-Border Transfers

The Software collects and stores no personal information on any server, so no transfer of personal information abroad is initiated by us.

When you interact with us through platforms such as GitHub or Bilibili, information may be transferred to servers in countries or regions where those platforms operate, governed independently by their privacy policies.

## 14. Minors

The Software is not designed for minors and does not actively collect their personal information. If you are a minor, please read this Policy with your guardian and use the Software only with your guardian's consent.

## 15. Information Security

Because the Software collects and stores no personal information on any server, there is no risk of exposure through a server-side data breach. The security of locally read and written files depends on your device and operating system safeguards; keep your device secure and your system up to date.

## 16. Your Privacy Rights

We respect your ability to know about, access, correct, transfer, restrict the processing of, and delete personal information. Because we do not collect or store personal information, we hold no records to query, correct, or delete; we guarantee your right to communicate with us about this Policy without discrimination.

If we ever rely on your consent as a legal basis for processing personal information, you may withdraw consent at any time without affecting the lawfulness of prior processing.

You may exercise your rights as follows:

- manage or delete local caches, logs, preferences, LaunchAgents, and recovery materials as described in Article 7 after completing restoration of any managed migrations; uninstalling the Software does not automatically delete external apps, data, or signature originals;
- request correction or removal of published sponsor information at any time under clause 18;
- lodge a complaint with the relevant supervisory authority if you believe our handling infringed your lawful rights.

## 17. Changes to This Policy

We may revise this Policy from time to time. When we do, the "Last updated" and "Effective date" at the top of this page will be updated accordingly. For material revisions that substantially affect your rights, we will give notice in the changelog and GitHub release notes.

The Simplified Chinese version of this Policy prevails; translations are provided for reference only.

## 18. Contact

For any question, comment, or complaint about this Policy or about the protection of personal information, contact us at:

**Email: a@shimoko.com**

We will respond to your request within fifteen business days of receipt.
