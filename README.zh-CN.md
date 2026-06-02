# SandboxServer

[English](README.md) · **简体中文**

一个 **仅 DEBUG 生效的 iOS SDK**,集成后即可把任意 App 变成可在浏览器里调试的目标。调用 `start()`
后,用同一局域网内的浏览器即可:

- 🗂 **沙盒文件浏览** —— 列目录 / 预览 / 编辑 / 下载 / 删除,支持 Range 流式,路径限定在允许根内(**已上线**)
- 🌐 **网络请求实时抓取** —— 每条 `URLSession` 请求都可实时查看(**已上线**)
- 🗄 **数据库查看** —— 发现 SQLite 库、浏览表/结构、运行只读 SQL(**已上线**;Core Data/Realm 与写入后续)
- 📜 **实时日志** —— 把 App 的控制台输出(`SandboxServer.log`,以及开启控制台捕获后的 `print`/`NSLog`)实时推到浏览器,可按级别过滤(**已上线**)
- 📱 **屏幕镜像 + 操作** —— 在浏览器里实时看到 App 界面并操作:点按(UIControl / SwiftUI 按钮)、**滑动/滚动与拖拽**(真实合成触摸)、输入、粘贴(**已上线,iOS**)
- 🌳 **视图层级** —— 在浏览器里以列表或 **3D 图层浏览器** 查看实时视图树(尺寸、类名、标签、缩略图)(**已上线,iOS**)
- 🔌 **WebSocket 抓取** —— 每个 `URLSessionWebSocketTask` 连接及其收发帧,实时(**已上线**)
- 📈 **性能 HUD** —— 实时 FPS / CPU / 内存占用 / 温度状态,推流并绘制图表(**已上线**)
- 📦 **App Bundle 检查器** —— Info.plist、Mach-O 架构与加固、描述文件、隐私、plist 解码(**已上线**)
- ⚙️ **UserDefaults 编辑** —— 浏览、编辑、删除、重置 App 的持久化偏好与 App Group suite(**已上线**)
- 📲 **设备信息** —— 一眼看全机型 / 系统 / 语言区域 / 屏幕与安全区 / 电量 / 内存 / 剩余磁盘(**已上线**)
- ⛓️ **Deep Link 触发** —— 列出 App 的 URL scheme,并在 App 内打开任意 scheme / universal link(**已上线,iOS**)
- 🔔 **通知测试** —— 查看/请求通知授权、发本地通知、模拟远程 push 负载(**已上线,iOS**)
- 🖥 **内置 Web 控制台** —— 由 SDK 自己提供,无需安装任何 App,打开一个 URL 即可
- 🤖 **MCP 工具** —— 把同一套设备端 API 暴露给 AI 客户端(Claude Code / Desktop)

它在宿主进程内、基于 Apple 的 Network.framework 跑一个内嵌 HTTP + WebSocket 服务,**零第三方运行时依赖**。

> ⚠️ 本 SDK 会开放宿主 App 沙盒的完整读写权限。它 **默认关闭**,必须显式 `start()`,默认只绑定
> loopback,且在 Release/App Store 构建里 **物理上不存在**。Token 鉴权是可选项；如果用
> `.localNetwork` 且不启用 token,同一可信 LAN 上的设备都能访问控制台。请用非生产账号、在可信网络下使用。

---

## 架构

```
┌─ 宿主 iOS App(DEBUG)──────────────────────────────┐
│  SandboxServer.shared.start()                        │
│     │                                                │
│     ▼                                                │
│  SandboxServerCore                                   │
│   ├ NetworkFrameworkTransport (NWListener/NWConn)    │
│   ├ HTTP/1.1 + RFC 6455 WebSocket(手写)             │
│   ├ AuthGate + DNS-rebinding 防护(中间件)          │
│   ├ Router → PluginRegistry → WSHub                  │
│   └ 插件:net·fs·db·logs·screen·hierarchy·ws·         │
│          perf·bundle·defaults·device·deeplink·notify  │
│  对外提供:                                          │
│   • Web 控制台 (/, /assets/*)                        │
│   • REST + WS API (/__sandbox/api/v1, /__sandbox/ws) │
└──────────────────────────────────────────────────────┘
        ▲ 局域网 / localhost              ▲ 局域网 / localhost
        │                                │
   浏览器(Preact 控制台)         sandbox-mcp(stdio)──► Claude Code / Desktop
```

内核极小、与具体功能无关 —— **一切皆 `SandboxPlugin`**。插件自描述的能力
(`GET /__sandbox/api/v1/plugins`)同时驱动:控制台渲染哪些面板、以及 MCP 桥注册哪些工具。

| 模块 | 职责 |
| --- | --- |
| `SandboxServerAPI` | 零依赖的公开契约(`SandboxPlugin`、请求/响应、配置)。 |
| `SandboxServer` | 始终被链接的门面。DEBUG + trait 时转发到 Core,否则转发到 no-op 桩。 |
| `SandboxServerNoOp` | Release / 关闭态构建中链接的惰性镜像。 |
| `SandboxServerCore` | 真实服务:传输、路由、Hub、注册表、内置插件、Web 资源。 |
| `web-src/` | Preact + TypeScript 控制台(Vite)。构建产物提交在 `Sources/SandboxServerCore/Resources/web/`。 |
| `mcp-bridge/` | 独立的 `sandbox-mcp` npm 包(与 Swift SDK 分离)。 |

---

## 安装

### Swift Package Manager(推荐)

```swift
dependencies: [
    .package(url: "https://github.com/your-org/SandboxServer.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        // 仅在 debug 构建配置里启用真实服务:
        .product(name: "SandboxServer", package: "SandboxServer",
                 condition: .when(traits: ["SandboxServerEnabled"])),
    ]),
]
```

为 debug 构建启用 `SandboxServerEnabled` trait。不启用(Release)时,包会链接惰性的 no-op 产品,服务在物理上不存在。

### CocoaPods

```ruby
pod 'SandboxServer', :configurations => ['Debug']
```

`:configurations => ['Debug']` 能把二进制 **以及 Web 资源** 都挡在 Release 之外。
(CocoaPods 支持目前为初步状态 —— 发布前请用 `pod lib lint` 校验。)

---

## 使用

```swift
import SandboxServer

#if DEBUG
Task {
    // 内置插件(网络/文件/数据库)由配置自动注册。
    let result = await SandboxServer.shared.start()        // 默认 .loopback、全部内置插件
    if case .started(let info) = result {
        print("打开 \(info.consoleURL)")                    // 需要 ?token= 时显式设置 auth: .token
    }
}

// 只启用部分内置插件,或注册你自己的插件(实现公开的 `SandboxPlugin` 协议):
// SandboxServer.shared.register(MyCustomPlugin())
// await SandboxServer.shared.start(SandboxConfig(builtInPlugins: [.network]))
#endif
```

控制台 URL 会打印到 Xcode 控制台。在 **模拟器** 上直接打开
(`http://127.0.0.1:<port>/`)。在 **真机** 上,用 `.localNetwork` 启动,再用同一 Wi-Fi 下的浏览器打开打印出的局域网 URL:

```swift
await SandboxServer.shared.start(SandboxConfig(bindingPolicy: .localNetwork))
```

`.localNetwork` 需要在 **debug** 的 Info.plist 里配置 `NSLocalNetworkUsageDescription`(以及
`NSBonjourServices` 列出 `_sandboxserver._tcp`)。

---

## MCP(AI 工具)

`mcp-bridge/` 是一个独立的 MCP 服务,代理设备 API。把 AI 客户端指向它:

```json
{
  "mcpServers": {
    "sandbox": {
      "command": "npx",
      "args": ["-y", "sandbox-mcp"],
      "env": { "SANDBOX_HOST": "127.0.0.1", "SANDBOX_PORT": "8080" }
    }
  }
}
```

它会先发现设备(env/flags → 单个 Bonjour 匹配),再按插件声明的能力动态注册 MCP 工具
(`net_list_requests`、`fs_read_file`、`db_query` 等)。详见 `mcp-bridge/README.md`。

---

## 开发

```bash
# Swift 包(SDK 本体)
swift build --traits SandboxServerEnabled          # 构建真实内核
swift test  --traits SandboxServerEnabled          # 单元 + 端到端测试
swift build                                        # 构建 Release 安全的 no-op 路径

# Web 控制台(Preact)
cd web-src && npm install && npm run build          # 产物 → Sources/SandboxServerCore/Resources/web
VITE_API_BASE=http://<device-ip>:<port> npm run dev # 对着运行中的设备做 HMR

# MCP 桥
cd mcp-bridge && npm install && npm run build
```

### 本地开发宿主(浏览器,无需设备)

`SandboxServerDevHost` 在 macOS 上启动真实内核,让你**无需 iOS App** 就能在浏览器里打开控制台 ——
联调 `web-src/` 或 REST/WS API 时很方便:

```bash
swift run --traits SandboxServerEnabled SandboxServerDevHost   # 然后打开它打印的 http://127.0.0.1:8080/ 地址
```

环境变量(都是“设了即开”);`Ctrl-C` 停止:

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `PORT` | 监听端口 | `8080` |
| `TOKEN` | 要求会话 token(地址变成 `…/?token=…`) | 关(`auth: .none`) |
| `CAPTURE` | 把 `print` / `NSLog` 重定向进日志面板(`captureConsole`) | 关 |
| `LOGSEED` | 启动即发示例日志 + 每 2 秒一条心跳,让日志面板有数据 | 关 |
| `SEED` | 发几条示例请求,让网络面板有数据 | 关 |

```bash
PORT=8092 LOGSEED=1 SEED=1 swift run --traits SandboxServerEnabled SandboxServerDevHost
```

它绑定 loopback,并把临时目录注册为额外的可浏览/可写根。作为 macOS 宿主没有 UIKit,所以
**屏幕镜像** 与 **视图层级** 面板会报不支持 —— 这两项请用 `Examples/Showcase/run.sh`(iOS 模拟器)。它没有
备用端口,`PORT` 被占就会快速失败 —— 换一个空闲端口即可。

完整架构说明与待决问题见 `CLAUDE.md`。
