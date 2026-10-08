# 日志与诊断

AppPorts 内置日志系统，用于记录应用运行期间的关键事件、迁移操作、系统信息和错误详情。遇到问题时，可导出诊断包并提交至项目 [Issues](https://github.com/wzh4869/AppPorts/issues)，以协助排查。

## 日志记录内容 <a href="#日志记录内容" id="日志记录内容"></a>

### 启动会话信息 <a href="#启动会话信息" id="启动会话信息"></a>

每次启动 AppPorts 时，日志会记录以下信息：

| 项目 | 说明 |
|------|------|
| 会话 ID | 本次运行的唯一标识（8 位 UUID 前缀） |
| 进程 ID | 系统进程标识 |
| Bundle ID | 应用标识符 |
| 应用语言 | 当前选择的语言代码 |
| 系统区域 | 系统区域设置标识 |
| 时区 | 当前时区标识 |
| 首选语言列表 | 系统首选语言顺序 |

### 系统诊断信息 <a href="#系统诊断信息" id="系统诊断信息"></a>

| 项目 | 说明 |
|------|------|
| 应用版本 | 版本号与构建号 |
| macOS 版本 | 系统版本及营销名称（如 "macOS Sequoia 15.x"） |
| 设备型号 | 型号及友好名称（如 "MacBook Pro (14-inch, M3 Pro, 2023)"） |
| 处理器信息 | 品牌字符串、核心数、活跃核心数 |
| 物理内存 | 内存总量 |

### 外部存储信息 <a href="#外部存储信息" id="外部存储信息"></a>

选择外部存储卷时，日志会记录以下信息：

| 项目 | 说明 |
|------|------|
| 卷名称 | 存储卷名称 |
| 总容量 / 可用空间 | 存储空间信息 |
| 文件系统格式 | 如 APFS、HFS+、exFAT 等 |
| 接口协议 | USB、Thunderbolt、NVMe/SATA |
| 设备速度 | 传输速率信息 |
| 块大小 | 存储块大小 |
| 卷 UUID | 存储卷唯一标识 |

### 迁移操作事件 <a href="#迁移操作事件" id="迁移操作事件"></a>

每次迁移操作都会生成唯一的操作 ID（如 `data-migrate-ABCD1234`），并记录：

- 操作开始与结束。
- 每个步骤的进度，包括复制、删除原始目录、创建符号链接和回滚。
- 步骤前后的路径状态快照，包括存在性、权限、大小、符号链接目标和不可变标志。
- 残留迁移数据检测与自动恢复。
- 文件复制进度、错误与重试。

### 迁移性能报告 <a href="#迁移性能报告" id="迁移性能报告"></a>

| 项目 | 说明 |
|------|------|
| 应用名称 | 迁移的应用名 |
| 数据大小 | 迁移数据量 |
| 耗时 | 迁移持续时间（秒） |
| 传输速度 | 传输速率（MB/s） |
| 源路径 / 目标路径 | 迁移起止路径 |

### 错误详情 <a href="#错误详情" id="错误详情"></a>

错误日志会包含结构化信息：

| 字段 | 说明 |
|------|------|
| 错误描述 | 人类可读的错误说明 |
| 错误类型 / 域 / 码 | NSError 结构化信息 |
| 错误码 | AppPorts 内部错误码（见下表） |
| 失败原因 | 详细失败原因 |
| 恢复建议 | 系统提供的恢复建议 |
| 文件路径 | 涉及的文件路径 |
| 关联路径 | 操作涉及的相关应用路径（`relatedURLs`） |
| 底层错误 | 嵌套错误递归记录 |

### 错误码 <a href="#错误码" id="错误码"></a>

| 错误码 | 含义 |
|--------|------|
| `BACKUP-SIGNATURE-FAILED` | 签名备份失败 |
| `APP-MOVE-DESTINATION-CONFLICT` | 应用迁移目标已存在，且不能确认可安全替换 |
| `APP-RESTORE-LOCAL-CONFLICT` | 迁回本地时发现无法自动覆盖的本地同名项目 |
| `DATA-MIGRATE-DESTINATION-CONFLICT` | 数据目录迁移目标已存在，且 metadata 未完整匹配 |
| `RESIGN-FAILED` | 重签名失败（应用可能无法通过 macOS 签名校验） |
| `DATA-RESIGN-FAILED` | 数据目录迁移后自动重签名失败 |
| `RESIGN-REFUSED-SANDBOXED` | 拒绝对沙盒应用重签名 |
| `RESTORE-SIGNATURE-IDENTITY-UNAVAILABLE` | 原始签名证书不在本机，拒绝恢复 |
| `CONTAINER-MOUNT-*` | 挂载迁移各阶段失败，如 `CONTAINER-MOUNT-EXTERNAL-NOT-APFS`、`CONTAINER-MOUNT-SWITCH-FAILED` |
| `CONTAINER-RESTORE-*` | 挂载迁移目录还原各阶段失败 |
| `DATA-BACKUP-SIGNATURE-FAILED` | 数据目录迁移前签名备份失败（后续恢复签名将无法使用原始身份） |

### 数据目录操作上下文 <a href="#数据目录操作上下文" id="数据目录操作上下文"></a>

数据目录操作（迁移、恢复、规范化、重新链接）的日志会自动包含关联应用的上下文信息：

| 字段 | 说明 |
|------|------|
| `app_name` | 关联应用名称 |
| `app_status` | 应用状态（已链接、本地等） |
| `app_is_resigned` | 应用是否已被重签名 |
| `app_bundle_id` | 应用的 Bundle ID（基于真实路径读取） |
| `app_real_path` | 应用的真实外部路径 |

### 操作摘要 <a href="#操作摘要" id="操作摘要"></a>

每个迁移操作生成 `OperationSummaryRecord` 记录，保留最近 100 条：

| 字段 | 说明 |
|------|------|
| `operationID` | 操作唯一标识 |
| `category` | 操作类别（`app_move`、`data-migrate`、`file-copy` 等） |
| `result` | 结果（`success`、`failed`、`rolled_back`、`success_with_warning`） |
| `errorCode` | 错误码（如有） |
| `startedAt` / `endedAt` | 起止时间 |
| `durationMs` | 耗时（毫秒） |

## 日志配置 <a href="#日志配置" id="日志配置"></a>

### 存储位置 <a href="#存储位置" id="存储位置"></a>

默认日志路径：

```text
~/Library/Application Support/AppPorts/AppPorts_Log.txt
```

可通过以下方式自定义日志位置：

- 菜单栏 → 日志 → 设置日志位置。
- 设置 → 日志设置 → 自定义路径。

### 日志格式 <a href="#日志格式" id="日志格式"></a>

```text
[2026-05-08 09:30:00] [INFO] [session:a1b2c3d4] [pid:12345] 应用启动
[2026-05-08 09:30:01] [DIAG] [session:a1b2c3d4] [pid:12345]   app_version: 1.6.1 (123)
[2026-05-08 09:30:05] [PERF] [session:a1b2c3d4] [pid:12345]   迁移完成: 2.3 GB, 45.2 MB/s, 52.1s
```

### 日志级别 <a href="#日志级别" id="日志级别"></a>

| 级别 | 说明 |
|------|------|
| `INFO` | 一般信息 |
| `ERROR` | 错误信息（含结构化错误详情） |
| `DIAG` | 系统诊断信息 |
| `DISK` | 外部存储卷信息 |
| `PERF` | 迁移性能报告 |
| `TRACE` | 底层路径状态与文件夹监控 |
| `DEBUG` | 调试信息（大小计算、嵌套目录检查） |
| `WARN` | 警告（残留迁移数据、恢复模式） |

### 日志轮转 <a href="#日志轮转" id="日志轮转"></a>

- 默认最大大小：**2 MB**（可配置为 1 MB、5 MB、10 MB、50 MB 或 100 MB）。
- 超出限制时自动截断：丢弃较旧的一半行，保留较新的一半。

## 导出诊断包 <a href="#导出诊断包" id="导出诊断包"></a>

当遇到问题需要反馈时，请导出诊断包并附带在 Issue 中。

### 导出方式 <a href="#导出方式" id="导出方式"></a>

**方式一：菜单栏**

1. 点击菜单栏 → 日志 → 导出诊断包。
2. 选择保存位置。
3. 系统会自动生成 `.zip` 文件，并在 Finder 中打开。

**方式二：设置页面**

1. 打开 AppPorts → 右上角设置。
2. 找到「日志设置」区域。
3. 点击「导出诊断包」按钮。
4. 选择保存位置。

### 诊断包内容 <a href="#诊断包内容" id="诊断包内容"></a>

导出的 `AppPorts-Diagnostic-<日期时间>.zip` 包含：

| 文件 | 格式 | 说明 |
|------|------|------|
| `diagnostic-summary.json` | JSON | 元数据（会话 ID、版本、区域、时区等） |
| `diagnostic-summary.txt` | 纯文本 | 人类可读的诊断摘要 |
| `recent-operations.json` | JSON | 最近 100 条操作记录 |
| `recent-failures.json` | JSON | 最近 20 条失败/警告操作 |
| `AppPorts_Log.share-safe.txt` | 纯文本 | 完整日志（已脱敏） |

### 隐私保护 <a href="#隐私保护" id="隐私保护"></a>

诊断包中的日志文件经过脱敏处理：

| 原始内容 | 替换为 |
|----------|--------|
| 用户主目录路径（如 `/Users/john`） | `/Users/<redacted-user>` |
| 外部存储卷名（如 `/Volumes/MyDrive`） | `/Volumes/<redacted-volume>` |
| `$HOME` 完整路径 | `~` |

## 提交 Issue <a href="#提交-issue" id="提交-issue"></a>

获取诊断包后，请按以下步骤提交：

1. 访问项目 [Issues](https://github.com/wzh4869/AppPorts/issues) 页面。
2. 点击「New Issue」，选择 Bug 报告模板。
3. 描述问题现象和复现步骤。
4. 将诊断包 `.zip` 文件拖拽至附件区域上传。
5. 提交 Issue。

{% hint style="success" %}
**提高反馈效率**

提交 Issue 时附带诊断包，可显著加快问题定位速度。诊断包包含完整的操作历史、错误详情和系统环境信息，开发者无需反复沟通即可复现和分析问题。
{% endhint %}
