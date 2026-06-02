# Tasks — 真实感 SwiftUI 示例

一个**像真实 app**的 SwiftUI 待办应用,用来演示「把 SandboxServer 接进你自己的 app」之后控制台会看到什么。
与同目录的 [`Showcase`](../Showcase) 不同 —— `Showcase` 是个「面板填充器」,启动就 seed 大量假数据把每个面板撑满;
这个示例**不 seed 假数据**,所有内容都来自真实的用户操作和一次真实的网络拉取,所以你在控制台里看到的就是
一个普通 app 自然产生的状态。

数据如何对应到控制台各面板:

| 你在 app 里做的事 | 落到哪里 | 对应控制台面板 |
| --- | --- | --- |
| 增/删/改/勾选待办 | SQLite `tasks.sqlite`(`Documents/`) | **Databases**(只读浏览、跑 SELECT) |
| 编辑某条待办的备注 | `Documents/notes/task-<id>.md` 纯文本文件 | **Files**(浏览、下载、编辑、删除) |
| 首启「导入示例」/「同步」 | 真实 HTTP 请求(`jsonplaceholder.typicode.com`) | **Network**(抓包、看 body、Replay) |
| 任意操作 | 结构化日志 + `print` | **Logs**(实时 tail、按级别/关键字过滤) |
| 设置页(用户名/排序/隐藏已完成/上次同步) | `UserDefaults` | **Defaults**(读/改/删) |
| —— | —— | **Screen / 视图层级 / Perf / Device** 等开箱即用 |

> 首启会从公共示例 API 拉一批待办作为初始数据;**没网也能用** —— 拉取失败时会本地插入几条引导用的待办,
> 并在 Logs 面板里记录这次失败。

## 一键运行

```bash
cd Examples/Tasks && ./run.sh
# 生成工程 → 构建 → 安装到已启动的模拟器 → 启动 → 打印并打开控制台 URL
```

## 手动

```bash
cd Examples/Tasks
xcodegen generate
SIM=$(xcrun simctl list devices booted | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()' | head -1)
xcodebuild -project SandboxTasksDemo.xcodeproj -scheme SandboxTasksDemo \
  -destination "id=$SIM" -derivedDataPath .build build
xcrun simctl install "$SIM" .build/Build/Products/Debug-iphonesimulator/SandboxTasksDemo.app
xcrun simctl launch --console-pty "$SIM" com.sandboxserver.tasks   # 控制台会打印 URL
```

也可在设置页(Settings tab)里直接看到、复制控制台 URL。

## 集成只有几行

整个 SDK 接入集中在 [`Sources/TasksApp.swift`](Sources/TasksApp.swift) 的 `DebugConsole` 里:`DEBUG` 下
`SandboxServerCore().start(.init(bindingPolicy: .localNetwork, captureConsole: true))`,拿到 `consoleURL`
即可。其余代码全是一个普通待办 app —— 这正是重点:**业务代码不需要为调试工具改任何东西。**

为避免依赖 Xcode 的 SPM trait 工具支持,这个示例和 `Showcase` 一样**直接链接 `SandboxServerCore` 产品**。
**生产 App 请改用 `SandboxServer` 门面 + 启用 `SandboxServerEnabled` trait**(Xcode → Package Dependencies
面板勾选),这样 Release 构建会链接惰性 no-op,服务在物理上不存在。详见仓库根目录 README。
