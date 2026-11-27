# 简介

AppPorts 是一款免费、开源的 macOS 应用与数据迁移工具。它帮助你把占空间的应用、应用数据和自己的文件夹放到外部存储，并管理本地入口、接回和还原。你可以保留需要的内容，同时为 Mac 的内置存储腾出空间。

应用和数据可以分别迁移。例如，你可以只搬走一个大型应用，也可以把应用留在本机，只迁移它支持迁移的数据目录。不同内容有不同的限制，AppPorts 会根据所选项目提供相应操作。

使用 AppPorts 前，请先了解[边界与共识](/docs/consensus)，看看它能做什么、不能做什么，以及为什么需要提前做好备份。

## 这份文档怎么用 {#reading}

这份文档面向日常使用 AppPorts 的用户，帮助你完成准备、迁移、还原，以及遇到问题后的处理。

- **第一次使用**：从[快速开始](/docs/faststart)完成安装和一次迁移。
- **已经知道要搬什么**：直接看[迁移应用](/docs/core)或[迁移数据](/docs/datamigrae/operation)。
- **想把内容搬回来或恢复入口**：看[还原、接回与解除链接](/docs/restore)。
- **想知道为什么这样设计**：阅读“原理”；想了解实验过程与方案取舍，再看[博客](/docs/blog/overview)。
- **遇到陌生名词或异常提示**：查[名词解释](/docs/glossary)、[徽章与状态](/docs/badges)或[常见问题与排查](/docs/faq)。

当前文档按最新界面和行为整理，包含尚未随正式版发出的开发改动。已发布版本的变化见[更新日志](/docs/changelog)；使用较早版本时，请留意文中的版本说明。

还可以参考 [DeepWiki 上的 AppPorts 文档](https://deepwiki.com/wzh4869/AppPorts)进一步了解项目。AppPorts 的来源，见[作者的博客文章](https://www.shimoko.com/p/appports/)。

想了解迁移方案是怎样形成的，可以阅读[博客](/docs/blog/overview)：从实验过程与失败结果中，了解 AppPorts 的取舍。

## AppPorts 的产品哲学 {#philosophy}

| 原则 | 对使用意味着什么 |
| --- | --- |
| 透明体验 | 尽量保留熟悉的打开方式，让应用搬到外置盘后仍能从本地入口启动。 |
| 策略稳定 | 优先采用经过验证的方式；遇到无法确认的数据、权限或目标冲突时，先说明问题。 |
| 低系统负担 | 减少不必要的后台工作；磁盘维护与应用更新守护按事件和实际状态运行，也可在设置中关闭。 |
| 广泛国际化 | 让更多语言的用户能够使用 AppPorts，并持续改善翻译。 |
| 无障碍友好 | 为界面操作、状态提示和辅助技术提供支持。 |

这些原则也意味着保留选择：只迁移应用的用户不必先研究容器数据；不满足挂载条件时，可以让数据继续留在本机。迁移后的内容仍依赖外置盘，重要数据也仍需要备份。

## 开始之前 {#before-start}

先了解要搬的是应用本体还是应用数据，再确认外置盘和权限。AppPorts 不会把不支持的目录变成可迁移目录，也不能保证任意应用在任意存储设备上都能照常工作。

[![侧栏按内容分为「应用」「工具目录」「应用数据」和「目录迁移」。图中选中了「目录迁移」，右侧可添加本地文件夹。](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-navigation-e9d2f12c105517f2.png?sign=YXYXzqUxWXjfroVApwggGfQ0rJu9H2ScYHnjNVr6iMc%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-navigation-e9d2f12c105517f2.png?sign=YXYXzqUxWXjfroVApwggGfQ0rJu9H2ScYHnjNVr6iMc%3D%3A0)

*侧栏按内容分为「应用」「工具目录」「应用数据」和「目录迁移」。图中选中了「目录迁移」，右侧可添加本地文件夹。*

继续阅读：[边界与共识](/docs/consensus) · [快速开始](/docs/faststart) · [外置盘与日常使用](/docs/storage-guide) · [隐私政策](/docs/privacy) · [开源许可](/docs/licenses)
