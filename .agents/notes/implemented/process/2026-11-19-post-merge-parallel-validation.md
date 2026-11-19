# Agent Note: 合并后验证并行执行测试和构建

Status: implemented

## Problem

[build 77 的串行验证](https://github.com/wzh4869/AppPorts/actions/runs/44534164221)用时约 18 分钟。准备测试包和执行三项检查约 10 分钟，随后 Release 构建约 7 分钟。Release 洁净构建拥有自己的编译输入，可以在测试运行期间开始。

## Decision

`Post-merge Tests` 和 `Post-merge Release Build` 分别使用 `macos-latest`。测试侧在同一 runner 上准备和复用 Debug 测试包，保留串行回归、隔离的进程计时以及 advisory 本地化。构建侧校验 App 包和 ZIP，将 ZIP 作为保留一天的候选产物上传。最终 `Post-merge Validation` 等两边结束，要求测试和构建 job 均成功才上传 `AppPorts-Unsigned`。候选包可用于诊断，最终产物名仍表示必过检查成功。

测试诊断沿用 `Post-Merge-Diagnostics`，构建诊断使用 `Post-Merge-Release-Diagnostics`。两个 job 均记录各步骤实际结果。诊断保留五天。

## Alternatives considered

- 在同一 runner 上同时启动测试和构建可以避免额外排队，且便于直接上传 ZIP。然而两项工作会争用 CPU 和磁盘。迁移用例本身还依赖外部命令的时限，已有串行约束需要保留。
- 按耗时拆分回归套件可以继续缩短测试路径，但要在多个 runner 上分别准备或传递测试包，并维护完整的用例分组。先移除实测约 7 分钟的串行构建等待，再用运行数据判断分片收益。

## Consequences

成功时等待时间主要由较慢的测试侧决定。每次运行多用一个 macOS runner，测试失败时已经启动的 Release 构建仍会执行。最终汇总使用 Ubuntu runner，仅传递已经检查过的 ZIP 并保留正式产物的上传条件。

## Verification

- 相同应用源码和 `arm64` Xcode 26.6（17F113）下，[串行 main](https://github.com/wzh4869/AppPorts/actions/runs/44537461355) 用时 16 分 17 秒，[并行验证](https://github.com/wzh4869/AppPorts/actions/runs/44539536423) 用时 10 分 55 秒，缩短 5 分 22 秒。两次回归均报告 859 项 XCTest（32 项跳过）和 784 项 Swift Testing，另有 14 项进程计时测试、19 项本地化审计。三路测试和 Release 洁净构建均通过。候选与最终 ZIP 逐字节一致，最终 ZIP 通过解压校验。
- [故意让回归步骤失败](https://github.com/wzh4869/AppPorts/actions/runs/44538168338)时，Release 和候选 ZIP 上传仍成功，最终检查失败且产物列表没有 `AppPorts-Unsigned`。
- [首轮验证](https://github.com/wzh4869/AppPorts/actions/runs/44538168841) 编译、ZIP 校验和测试通过，GitHub `CreateArtifact` 连续五次超时导致候选上传失败。同一提交重跑成功。
