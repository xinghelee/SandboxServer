# SandboxServerDemo

一个最小 iOS demo,用来在模拟器上验证 SandboxServer：启动时拉起内嵌调试服务、打几条网络请求,
界面直接显示**控制台 URL + token**。Demo 使用 `localNetwork` 绑定,所以同一可信 LAN 上的浏览器
也可以打开显示的 `http://<device-ip>:8080/?token=…` 来查看 Web 控制台和实时抓包。

## 一键运行

```bash
cd Demo && ./run.sh
# 自动:生成工程 → 构建 → 安装到已启动的模拟器 → 启动 → 打印并打开控制台 URL
```

## 手动

```bash
cd Demo
xcodegen generate
SIM=$(xcrun simctl list devices booted | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()' | head -1)
xcodebuild -project SandboxServerDemo.xcodeproj -scheme SandboxServerDemo \
  -destination "id=$SIM" -derivedDataPath .build build
xcrun simctl install "$SIM" .build/Build/Products/Debug-iphonesimulator/SandboxServerDemo.app
xcrun simctl launch --console-pty "$SIM" com.sandboxserver.demo   # 控制台会打印带 token 的 URL
```

## 集成说明

为避免依赖 Xcode 的 SPM trait 工具支持,这个 demo **直接链接 `SandboxServerCore` 产品**
(与 `swift run SandboxServerDevHost` 同一路径)。

**生产 App 应改用 `SandboxServer` 门面 + 启用 `SandboxServerEnabled` trait**(Xcode → 工程的
Package Dependencies 面板里勾选该 trait),这样 Release 构建会链接惰性的 no-op,服务在物理上不存在。
详见仓库根目录 README。
