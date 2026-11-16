# AppPorts 2.3.0（68）验证记录

本批改动将“检查”入口移入准备情况卡片，调整自更新应用的迁移选择和文案，移除列表中的框架标记，更新版本号，并修复两项 CI 测试夹具问题。WorkBuddy、网易云按普通应用迁移；其他检测到更新器的应用仍保留锁定与非锁定选择，非锁定高亮。提示不保证所有应用的更新都能恢复成功。

## 完整 runner 验证

验证对象为 `000cea9e1144b2fffdc7b7f3c5fea3ad2a646259`，版本 2.3.0（68）。[完整运行与诊断](https://github.com/wzh4869/AppPorts/actions/runs/43890629285)使用现有 workflow 和一次性 macOS runner，没有设置外盘或界面渲染环境变量。317 项构建输入的哈希与本地构建一致；后续验证记录提交只修改 Markdown，不改变构建输入。

| 检查 | 实际结果 |
| --- | --- |
| Debug 测试包构建 | 通过 |
| 完整应用回归 | XCTest 806 通过、31 跳过；Swift Testing 771 通过；0 失败 |
| 独立进程计时 | 14 通过，0 失败 |
| 本地化审计 | 18 通过、翻译完整性 1 失败 |
| arm64 / x86_64 Release clean build | 通过 |
| 应用包、可执行文件与 ZIP 校验 | 通过 |

本地化唯一失败是 `LocalizationAuditTests.testStringCatalogContainsTranslationsForAllSupportedLanguages`。维护者批准新增文案只完成中英文，其余语言暂用英文；目录仍有 420 个延期翻译槽位。没有填写假的翻译或放宽断言。workflow 为 success 是因为本地化属于 advisory，不代表全部翻译审计通过。

## CI 失败与修复

[旧 main 的窗口测试](https://github.com/wzh4869/AppPorts/actions/runs/43853013283)固定要求 1000 × 700；窗口显示后被屏幕边界限制为 1000 × 677，最后一条重开断言失败。夹具按可见屏幕限制尺寸并留出边界，首帧、替换桥接和重开断言全部保留，应用窗口代码没有修改。最终 runner 两项窗口测试均通过。

[build 67 第一轮](https://github.com/wzh4869/AppPorts/actions/runs/43885579492/attempts/1)的窗口测试通过，兼容性校验测试在私有镜像清理阶段失败：`hdiutil detach` 按挂载目录报 No such file or directory，lsof 确认目录已经不是挂载点。原代码重跑回归通过，说明该失败不是每轮必现；未确定 CI 中卷为何先被卸载。

本机用私有 APFS 镜像实际复现同类场景：先 `diskutil unmount`，旧夹具按目录分离失败，但只读查询确认镜像设备仍连接。修复记录本次 `hdiutil attach -plist` 返回的整盘设备号，以设备分离镜像，不把“目录不再挂载”直接当成分离成功。正常 busy 有限重试、持续错误、超时和取消边界不变，不使用强制卸载。新增真实回归在本机和最终 runner 均通过；生产迁移和卸载实现不变。

## 本地与界面

同批源码的功能专项 168 项通过；迁移提示渲染补拍 1 项通过。最后窗口与镜像专项合计 16 项通过，同证书双架构 Release clean build、严格全架构嵌套签名及产物版本核对通过。专项与完整 runner 结果分别记录。

- [准备情况检查入口](readiness-check-build63.md)
- [中英文更新迁移提示](update-migration-build65.md)

截图使用生产组件和隔离偏好，标明各自拍摄 build，不代表用户真实权限或第三方应用更新结果。此次没有重新执行真实第三方应用更新、权限切换、登录重启或物理断盘流程。安装版仍为 `/Applications/AppPorts.app` 的 2.2.1（65）；本轮没有替换安装版、创建版本标签或发布 Release。
