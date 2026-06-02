# Showcase — 全面板填充示例

一个把 SandboxServer **每个面板都撑满**的 iOS demo,用来在模拟器上快速验证 SDK:启动时 seed 大量
数据(~6k 行的 SQLite 表、~250 KB 文件、上百条网络请求 + WebSocket、几百条日志、各类型
UserDefaults……),界面直接显示**控制台 URL**。它使用 `localNetwork` 绑定且默认不校验 token,所以同一
可信 LAN 上的浏览器也可以打开显示的 `http://<device-ip>:8080/` 来查看 Web 控制台和实时抓包。

> 想看「真实 app 自然产生」的数据(而非 seed 假数据),用隔壁的 [`Examples/Tasks`](../Tasks)。

## 一键运行

```bash
cd Examples/Showcase && ./run.sh
# 自动:生成工程 → 构建 → 安装到已启动的模拟器 → 启动 → 打印并打开控制台 URL
```

## 手动

```bash
cd Examples/Showcase
xcodegen generate
SIM=$(xcrun simctl list devices booted | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()' | head -1)
xcodebuild -project SandboxShowcaseDemo.xcodeproj -scheme SandboxShowcaseDemo \
  -destination "id=$SIM" -derivedDataPath .build build
xcrun simctl install "$SIM" .build/Build/Products/Debug-iphonesimulator/SandboxShowcaseDemo.app
xcrun simctl launch --console-pty "$SIM" com.sandboxserver.showcase   # 控制台会打印 URL
```

## 集成说明

为避免依赖 Xcode 的 SPM trait 工具支持,这个 demo **直接链接 `SandboxServerCore` 产品**
(与 `swift run SandboxServerDevHost` 同一路径)。

**生产 App 应改用 `SandboxServer` 门面 + 启用 `SandboxServerEnabled` trait**(Xcode → 工程的
Package Dependencies 面板里勾选该 trait),这样 Release 构建会链接惰性的 no-op,服务在物理上不存在。
详见仓库根目录 README。
