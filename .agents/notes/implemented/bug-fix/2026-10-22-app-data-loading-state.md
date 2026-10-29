# Agent Note: 应用数据页区分“正在扫描”和“确实没有应用”

Status: implemented

## Problem

启动后立刻切到“应用数据”，左栏显示“应用 0 / 无本地应用”。此时应用扫描还没结束，`localApps` 还是空的；扫描完成后列表才出现。用户看到的是一个确定的否定结论，容易以为列表坏了或者应用丢了。

`localApps.isEmpty` 本身无法区分这两种情况，页面也没有拿到“应用列表还在扫”的信号——它已有的 `isScanning` 是数据目录扫描状态，不是应用列表扫描状态。

## Decision

`DataDirsView` 新增 `isScanningApps` 参数（默认 `false`，不影响其他调用点），由 `ContentView` 传入 `localScanState.isScanning`。左栏的占位按状态分流：

```swift
if localApps.isEmpty {
    if isScanningApps {
        ContentView.EmptyStateView(icon: "magnifyingglass", text: "正在扫描...".localized)
    } else {
        ContentView.EmptyStateView(icon: "app.dashed", text: "无本地应用".localized)
    }
}
```

右栏同样按状态分流：未选应用时，扫描中标题显示“正在扫描...”、占位图换成放大镜；扫描结束才回到“请从左侧选择应用 / 从左侧选择一个应用”。

复用已有的“正在扫描...”文案（22 种语言齐全），不新增本地化键。

页面动画与同上下文刷新呈现的后续调整见[页面切换与目录列表显示](2026-10-29-页面切换与目录列表显示.md)，本篇其余生命周期、权限和加载态约束继续适用。

## Alternatives considered

- **复用 `isScanning`**：它是数据目录扫描的绑定，语义不同，扫描应用时不一定为真。
- **新增“正在扫描应用…”文案**：表达更准确，但要补 22 种语言的翻译，收益不足。
- **扫描期间隐藏左栏**：会让右侧失去“从左侧选择应用”的上下文，页面显得残缺。

## Consequences

收益：扫描期间看到的是进行中的状态，扫描结束才给“无本地应用”的结论。

代价与边界：

- 右栏在扫描期间也显示扫描态，左右两侧不会互相矛盾。
- `isScanningApps` 默认 `false`，未传参的调用方保持原行为。

## Verification

用屏幕录制权限在新的构建上抓首屏截图：左栏显示“正在扫描…”与放大镜图标；同一进程数秒后显示应用列表。Release 构建通过（Apple Development，Team MQ7XG7WM3F）。
