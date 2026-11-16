# AppPorts build 61 验证记录

此次提交包含应用缓存解锁、权限重启前关闭弹窗、就绪入口与默认尺寸、默认开启的后台代理、更新任务跨进程状态、独立更新守护、AppPorts 自更新配合、App Store 配置检测和主窗口设置栅格。

验证对象为 `c4be282708531f0cd3bf0268a0112edd3822da12`。311 项应用、测试和 Xcode 构建输入的 SHA256 与本地已构建及已安装的 2.2.1（61）一致。此后的验证记录提交仅修改 Markdown，不改变这些构建输入。

## 一次性 macOS runner

[完整运行与诊断](https://github.com/wzh4869/AppPorts/actions/runs/43833574278) 使用现有 post-merge workflow 手动运行，未设置外盘或渲染环境变量。

| 检查 | 实际结果 |
| --- | --- |
| Debug 测试包构建 | 通过 |
| 完整应用回归 | XCTest 801 通过、30 跳过；Swift Testing 770 通过；0 失败 |
| 独立进程计时 | 14 通过，0 失败 |
| 本地化审计 | 18 通过、1 失败 |
| arm64 / x86_64 Release clean build | 通过 |
| 应用包、可执行文件与 ZIP 校验 | 通过 |

本地化唯一失败为 `LocalizationAuditTests.testStringCatalogContainsTranslationsForAllSupportedLanguages`。维护者明确要求新增文案先完成中英文、其余语言暂用英文；本轮额外提供繁中，20 个 key 在延期的 19 种语言中仍缺少 380 个翻译槽位。现有全语言审计保留失败，没有填入假的翻译或放宽断言。workflow 总状态为 success 是因为本地化为 advisory，不能将其描述为全量测试全部通过。

## 本地与实机

相关决策记录保留各模块的专项结果。最终设置、App Store、准备模型、权限引导和自更新专项共 79 项通过；同证书 Release clean build、严格整包签名、证书、指定要求与 entitlements 核验通过。

安装版 `/Applications/AppPorts.app` 为 2.2.1（61）。实机确认两个代理开启、48 点应用图标、实际运行路径、三项准备就绪和统一按钮。正常退出本体后更新守护持续运行；普通 open 返回 0，主窗口正常重开且守护 PID 不变。本轮临时 build 58、59、60 旧包核对身份、签名和无打开文件后清除。

本轮没有切换真实系统权限、执行实际后台应用更新或登录重启；这些流程不因构建、隔离测试或普通重开成功而视为已验证。

## 界面截图

以下截图由生产组件与隔离偏好生成，不代表用户真实权限或应用数据。完整渲染覆盖 660/940 点、中英文及法文英文回退、明暗、就绪/需处理状态和长路径。24 张整页图已逐张检查；中文宽页中官网、日志 Finder、导出、清空按钮背景实测均为 24 点高。

- [中文宽页，全部就绪](settings-build61-settings-zh-Hans-light-940.png)
- [中文宽页，需要处理](settings-build61-settings-zh-Hans-light-940-attention.png)
- [英文暗色宽页](settings-build61-settings-en-dark-940.png)
- [中文窄页](settings-build61-settings-zh-Hans-light-660.png)
