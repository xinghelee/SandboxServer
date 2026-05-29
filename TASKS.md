# SandboxServer 任务清单 / Roadmap

> **北极星:尽可能方便开发人员和测试人员。** 定位是内部使用的调试工具,服务基本只在
> loopback / 受信任开发网络上跑。因此本清单**按"开发/测试日常直接感受"排序**:
> 工具好用、不挡路 > 体验顺 > 功能趁手 > 防回归 > 顺手的健壮性 > (将来才需要的)发布卫生。
>
> 每条都对照真实源码核实并标注 `file:line`。可逐条勾选。已完成的 **#10 Web 体验增强**
> (网络状态筛选 / 复制 / curl·HAR 导出 / 日志按来源筛选)不在此列。

**图例** · 工作量 `S`(<半天)`M`(1–2 天)`L`(>2 天)· 影响 高/中/低

---

## A. 工具"就是好用、不挡路"(可靠性 + 核心可用性)— 先做

### [x] A1 · MCP bridge:所有设备调用加默认超时(不再无限挂死) ✅ 已完成 (ebbb881)
**工作量** S · **影响** 高 · 〔原 P1-4〕
**问题** `request()`/`fetchBody()` 透传 `opts.signal` 但无默认值(`deviceClient.ts:151-156,212`),卡死/休眠的设备会让任一工具调用永久挂起;连启动期 `healthz()`(`index.ts:72`)都能在 stdio 接好前把整个 bridge 挂死,对使用者表现为"卡住、毫无反馈"——最糟的体验。
**做法** 给 DeviceClient 加可配默认超时(`SANDBOX_TIMEOUT_MS`,默认 ~10s);`request()`/`fetchBody()` 用 `AbortSignal.any([opts.signal, AbortSignal.timeout(ms)])`;启动 healthz 用更短超时,缺设备时快速失败并打清晰 stderr。
**涉及** `mcp-bridge/src/deviceClient.ts` · `index.ts`
**验收** `node --test` 用永不 resolve 的 mock fetch 断言 `request()` 在超时内 reject。

### [x] A2 · WS 扇出:隔离慢/死订阅者并剪除(控制台/实时流不卡死) ✅ 已完成(每连接有界出队 + 失败剪除 + 单写者;半开心跳探测留作后续)
**工作量** M · **影响** 高 · 〔原 P1-3〕
**问题** `WSHub.publish` 用顺序 await 循环 `for target in targets { try? await target.send(frame) }`(line 59);hub 是 actor,一个被 TCP 背压卡住的订阅者会拖死其余订阅者和所有控制处理(net、logs 都走这里)——表现为控制台某个面板一卡、全部实时流跟着停。另外 `try?` 吞掉发送失败不剔除连接;`setReadTimeout(nil)` 使消失的半开 peer 永不回收。
**做法** 每个 Conn 配有界出站队列、per-connection task 排空(或每个 send 包成 Task),actor 不被最慢 peer 占住;保持顺序、溢出丢最旧(seq 让客户端察觉断档)。publish 收集 send 抛错的连接并移除。加粗粒度空闲截止或周期 ping 剪除死 peer。
**涉及** `WSHub.swift` · `SandboxServerCore.swift` · `Tests/.../WebSocketCodecTests.swift`
**验收** 用阻塞连接 double 断言快订阅者仍收事件、死连接被回收。

### [x] A3 · screen + hierarchy 面板的触摸/指针支持(真机/平板能点能滑) ✅ 已完成 (d69039d)
**工作量** M · **影响** 高 · 〔原 P1-12〕
**问题** 控制台会被 LAN 上的触摸设备打开,但 `screen.tsx:232-241`、`hierarchy.tsx:128-185` 仅用 mouse handler、无 Touch/Pointer 事件——平板/手机上点按/滑动/旋转**全失效**。而测试人员恰恰最常在触摸设备上开控制台。
**做法** 两面板换成 Pointer Events + `setPointerCapture`;`.screen-img`、`.h3d-wrap` 加 `touch-action:none` 防浏览器劫持手势;重建 web-src(产物提交进 Resources/web)。
**涉及** `web-src/src/panels/screen.tsx` · `hierarchy.tsx`
**验收** `npm run build` 通过;触摸设备上点按/滑动/旋转手动可用。

### [x] A4 · MCP bridge:把失败分类为 输入 / 设备 / 不可达(看得懂为什么失败) ✅ 已完成 (ddef5e1)
**工作量** M · **影响** 高 · **依赖** A1 · 〔原 P1-5 / 候选 #4〕
**问题** `buildCallback` 把一切失败塌缩成 `{text:'Error: <msg>'}`(`registerTools.ts:298-305`),丢掉 `status/code`;fetch 层失败(设备休眠、ECONNREFUSED)抛裸 `TypeError`。使用者(或 AI 客户端)分不清"改参数 / 设备返回 403·501 / 设备不可达",无法选择 重试·修正·唤醒设备。
**做法** `deviceClient.ts` 把 fetch 拒绝包成带类型 `TransportError`(unreachable=ECONNREFUSED/ENOTFOUND/timeout;protocol=非 2xx;input=调用前抛出);`buildCallback` 按类型输出带稳定 `kind`('input'|'device'|'unreachable')、HTTP status/code、一行修复提示的结构化结果。
**涉及** `mcp-bridge/src/deviceClient.ts` · `registerTools.ts`
**验收** `node --test`:ECONNREFUSED→unreachable、403→device 带 status、调用前抛出→input。

### [x] A5 · MCP bridge:设备断连检测 + 自动重解析/重注册(设备重启不用重启客户端) ✅ 已完成 (690516d)
**工作量** L · **影响** 中 · **依赖** A4 · 〔原 P2-11 / 候选 #6〕
**问题** `registerAll` 在 connect 时跑一次(`index.ts:78`)后永久驻留。设备重启后 per-`start()` token 轮换、绑定可能变,之后每个工具调用永久失败,使用者只能**重启整个 MCP 客户端**——长会话里很烦。
**做法** 加可选 reconnect supervisor:低频后台 healthz ping(用 A1 超时);持续失败时重跑 `resolveEndpoint()`(重读 env/flags、重浏览 Bonjour)就地换 endpoint;重连打 stderr banner;flag/env 门控使默认行为不变;与 A4 的 unreachable 分类配合。
**涉及** `mcp-bridge/src/index.ts` · `deviceClient.ts` · `discovery.ts`
**验收** 会话中重启设备,bridge 重解析、后续调用成功(手动 + 先失败后恢复的 node:test mock)。

---

## B. 日常体验更顺(可用性 / 体验)

### [ ] B1 · 在 net 面板提示抓包盲区(测试看到空面板不再误判)
**工作量** S · **影响** 中 · 〔原 P2-3〕
**问题** `SandboxURLProtocol` 覆盖 `URLSession.shared` + `.default`/`.ephemeral`,但 background session、WKWebView、raw socket、非 http scheme 被静默丢弃。今天没有任何信号——调 WKWebView 的人看到空面板会以为没发请求,白白排查半天。
**做法** `NetworkPlugin.capabilities` 加 limitations 说明(或放进 `GET requests` 的 meta);控制台 net 面板头渲染成一行 caption;可选 `activate()` 打一次性 warning。
**涉及** `NetworkPlugin.swift` · `SandboxURLProtocol.swift` · `web-src/src/panels/network.tsx`
**验收** plugins manifest 含 limitations;`npm run build` 后 net 头显示 caption。

### [ ] B2 · README/文档对齐已发布插件 + MCP 工具表(开发者找得到全部能力)
**工作量** S · **影响** 中 · 〔原 P2-4〕
**问题** SDK 发布**六个**插件(`SandboxConfig.swift` 的 `.all` 含 `.hierarchy`),但两个 README 止于五个(net·fs·db·logs·screen);`mcp-bridge/README.md:75-83` 还说"多数 fs/db 端点返回 501"——已过时(fs 已活、db 只读、logs/screen/hierarchy 工具都已发)。开发者据此**低估了工具能力、以为 fs/db 不可用**。
**做法** 两个 README 加 实时视图层级/3D 图层检查器 一条并把 `hierarchy` 追加进架构图(中英平行 1:1);重写 bridge 工具表加 logs/screen/hierarchy + fs_roots,替换 501 为准确 v1 状态,标注 ui_screenshot 图块与 readOnly/destructive 提示。
**涉及** `README.md` · `README.zh-CN.md` · `mcp-bridge/README.md`
**验收** 三个 README `grep -n hierarchy` 命中;bridge README 不再有 "501"。

### [ ] B3 · 虚拟化 network/logs/DB 列表 + 键盘/ARIA(海量日志仍流畅)
**工作量** L · **影响** 中 · 〔原 P2-9〕
**问题** 每行都进 DOM——network 1000(`network.tsx:16,188`)、logs 2000(`logs.tsx:10,166`)、DB 无界 loadMore(`db.tsx:129,205`),每条 live WS 行触发整列重渲,**高负载下卡顿**。nav 缺 aria-current、行是裸 `tr onClick`、抽屉不 trap/restore 焦点。
**做法** 做一个无依赖窗口化列表在三处复用(MAX_ROWS 作数据上限);nav 带 aria-current,行 role=button+tabindex+Enter/Space,抽屉 role=dialog、开聚焦关闭键、关时还原;重建 web-src。
**涉及** `web-src/src/panels/{network,logs,db,NetDetailDrawer}.tsx` · `main.tsx`
**验收** `npm run build` 通过;滚动 2000 行日志顺滑;键盘导航 + 抽屉焦点陷阱可用。

---

## C. 功能补全(更趁手)

### [ ] C1 · 实现 `net_replay_request`(重放抓到的请求)
**工作量** M · **影响** 中 · 〔原 P2-1〕
**问题** NetworkPlugin 注册了 `net_replay_request` 工具与 `POST requests/{id}/replay` 路由,但 handler 返回 `.notImplemented('Replay arrives in v2.')`(line 82-83)——bridge 暴露了一个**永远失败的工具**。对开发/测试来说"重放一个请求"是很趁手的能力,且 `SandboxURLProtocol.internalSession` 正好可无递归重发。
**做法** CapturedTransaction 存完整请求 body(或小则重取);`replayPayload(id)` 返回 method/url/headers/body,接受 `{headers,body}` 覆盖;经 internalSession 重发不被再抓;返回新响应。加端到端测试。
**涉及** `NetworkPlugin.swift` · `TransactionStore.swift` · `SandboxURLProtocol.swift`
**验收** `swift test --traits SandboxServerEnabled` 覆盖重放返回新响应。

### [ ] C2 · DB 表清单在大库变廉价 + 支持 HTTP 后缀 Range
**工作量** S · **影响** 中 · 〔原 P2-2〕
**问题** (1) `SQLiteReader.tables` 每次 `/tables` 对每表跑 `SELECT COUNT(*)`(line 62-65)——真实 Core Data 库上数秒全表扫,**每次开 DB 面板都卡**。(2) `byteRange`(`HTTPMessage.swift:38-45`)丢掉后缀 range `bytes=-500`,静默以 200 返整文件(影响断点续传/媒体预览)。
**做法** COUNT(*) 放到 `?counts=true` 后,否则 rowCount 返 null、面板展开前显示"—";`byteRange` 解析扩成枚举 `{explicit, suffix(Int)}`,在 `FilePlugin.read` 对已知大小解析(start=max(0,size-n))。配套单测。
**涉及** `SQLiteReader.swift` · `DBPlugin.swift` · `HTTPMessage.swift` · `FilePlugin.swift`
**验收** `swift test --traits SandboxServerEnabled` 覆盖 `?counts` 与 `bytes=-500` 返回正确尾部 206。

---

## D. 防回归测试(你点名要的:保工具不被改坏)

### [ ] D1 · 单测 FilePlugin 路径围栏(核心正确性,改动不踩雷)
**工作量** M · **影响** 高 · 〔原 P1-1〕
**问题** `FilePlugin.resolve` 把每个 fs/db 路径限制在允许根内,是 fs/db 一切操作的地基;grep 确认**零测试**触达它。即便是内部工具,一次回归也会让文件浏览/DB 行为悄悄出错。
**做法** 新建 `FilePluginResolveTests`:`../../etc/passwd`/越界绝对路径→nil;nil/空/`/`→首个根;`'/a/b'` vs `'/a/bb'` 前缀被拒(line 81 尾斜杠守卫);根内指向根外符号链接被拒;合法根下不存在的叶子可解析(PUT)。再驱动 handler 用越界 path 断言 403。
**涉及** `Tests/.../FilePluginResolveTests.swift`(新) · `FilePlugin.swift` · `PluginContext.swift`
**验收** `swift test --traits SandboxServerEnabled --filter FilePluginResolveTests`。

### [ ] D2 · 单测 Range 解析 + 206/416/Content-Range,以及顺序契约(LogStore 分页、WSHub per-channel seq)
**工作量** M · **影响** 高 · 〔原 P1-10〕
**问题** 这些都是前端控制台直接依赖的契约,却只被冒烟测过:`byteRange` 三分支 + `FilePlugin.read` 的 206/416 钳制(off-by-one 会损坏分段下载);`LogStore.list` 两形态 + 环形淘汰;`WSHub` per-channel 单调 seq(resume 契约)。macOS host 全可测。
**做法** `RangeReadTests`(byteRange 各情形 + read 状态码/Content-Range/切片长度)、`LogStoreTests`(tail/sinceSeq/nextCursor/过滤/淘汰且 seq 不复用)、`WSHubSeqTests`(双 channel seq 各自 1,2,3 且 payload 往返)。
**涉及** `Tests/.../{RangeReadTests,LogStoreTests,WSHubSeqTests}.swift`(新) · `FilePlugin.swift` · `WSHub.swift`
**验收** `swift test --traits SandboxServerEnabled --filter 'RangeReadTests|LogStoreTests|WSHubSeqTests'`。

### [ ] D3 · MCP bridge 单测 + CI 跑 NoOp 路径
**工作量** M · **影响** 中 · 〔原 P1-11〕
**问题** bridge 零测试(CI 只 tsc):`parseFlags`/`resolveEndpoint`(0-1-多 peer)/envelope·DeviceApiError 解包/`fillPath`/`pickQuery` 无覆盖。另外 `scripts/ci.sh` 构建 no-op 路径却从不在 trait 关闭下 `swift test`——坏掉的 no-op `start()` 或没编成空的测试会静默过 CI。
**做法** bridge 加 `node:test`+`tsx`(无新运行时依赖)覆盖上述及 jpegBase64 图块分支,加 `npm test`;`ci.sh` tsc 后调 `npm test`,加一个 trait 关闭的 `swift test` job;在 CLAUDE.md 记录该 no-op 测试命令。
**涉及** `mcp-bridge/package.json` · `discovery.ts` · `deviceClient.ts` · `scripts/ci.sh`
**验收** `ci.sh` 同跑 `npm test` 与 trait-OFF `swift test` 且通过。

### [ ] D4 · 让 HTTP 读超时可注入 + 快速 slow-loris 测试
**工作量** M · **影响** 中 · 〔原 P1-6;CLAUDE.md 点名〕
**问题** `NWServerConnection.defaultReadTimeout` 硬编码静态 30(line 120),无配置旋钮,导致半开连接清理逻辑不等 30s 就无法测、当前未测。一处竞态回归会静默发版。
**做法** `SandboxConfig` 加 `requestReadTimeout=30`(必要时镜像 NoOp);经 accept 路径穿到 `NWServerConnection.init`;加测试:裸 loopback socket 发部分 header 不终止、setUp 设 ~0.5s,断言 ~1s 内关闭;生产默认仍 30s。
**涉及** `SandboxConfig.swift` · `NetworkFrameworkTransport.swift` · `SandboxServerCore.swift` · `Tests/.../ReadTimeoutTests.swift`(新)
**验收** `swift test --traits SandboxServerEnabled --filter ReadTimeoutTests` ~1s 通过。

### [ ] D5 · 单测 Host 检查 + AuthGate 锁定 / ReleaseGuard 拒绝矩阵(偏安全,可后置)
**工作量** S · **影响** 中 · 〔原 P1-8 + P1-9〕
**问题** `MiddlewareChain.validateHost`(line 27-47,解析非平凡)、`AuthGate` 20 次/30s 锁定(line 34-40)、`ReleaseGuard.verify`(直读 `Bundle.main` 无注入缝,macOS 不可达)都未测。受信任网络下安全性优先级降低,但这些是廉价的正确性兜底。
**做法** `MiddlewareHostTests`(合法/非法 host 矩阵 + authed 路由 host 先于 token)+ AuthGate 锁定窗口;`ReleaseGuard` 抽出纯函数 `evaluate(isSimulator:isMacOS:isTestFlight:hasProvisioning:)`,单测五行矩阵。
**涉及** `Tests/.../{MiddlewareHostTests,ReleaseGuardTests}.swift`(新) · `MiddlewareChain.swift` · `AuthGate.swift` · `ReleaseGuard.swift`
**验收** 对应 `--filter` 通过。

### [ ] D6 · 强化 PublicAPICompatTests 捕获 NoOp/Core 新增式漂移
**工作量** S · **影响** 中 · 〔原 P2-5〕
**问题** 它只把两引擎绑成 `any SandboxServerEngine` 断言两次 `isRunning==false`,抓不到新增式漂移(给 Core 加公有方法不加协议/NoOp 仍能编)——而 CLAUDE.md 称这个双产品不变量"承重"。
**做法** 通过协议类型对两引擎跑遍全表面(register/setHostValue/addRoot/log/stop + 模式匹配 start 的 StartResult),签名变更强制两处更新;协议加"两个引擎都要加"注释。
**涉及** `Tests/.../PublicAPICompatTests.swift` · `SandboxServerEngine.swift` · `SandboxServerNoOp.swift`
**验收** `--filter PublicAPICompatTests` 通过且覆盖完整表面。

---

## E. 顺手的健壮性(受信任网络 → 不急,改到附近时顺带做)

### [ ] E1 · WS 帧体积上限(对齐 HTTP body cap)
**工作量** S · 〔原 P0-4,已降级〕 `WebSocket.swift:92` 缓冲攻击者可控 payloadLen 无上限。受信任网络下风险低、但极便宜:加 `maxFramePayloadBytes`(如 1 MiB),超限发 close 1009 并关闭。**涉及** `WebSocket.swift` · `WSHub.swift`。

### [ ] E2 · DB `ATTACH`/多语句守卫(SQLite authorizer)
**工作量** M · 〔原 P0-3,已降级〕 只读连接仍可 `ATTACH` 读 App 沙盒内其它 SQLite(`SQLiteReader.swift:104,116` 用户 SQL 直进 prepare_v2)。受信任 + 沙盒内,严重度低;cheap guard:装 `sqlite3_set_authorizer` 拒 ATTACH/写、单语句检查。**涉及** `SQLiteReader.swift` · `DBPlugin.swift`。

### [ ] E3 · WS upgrade 校验 Sec-WebSocket-Version(426),可选 Origin 限制
**工作量** S · 〔原 P2-10〕 `handleWebSocketUpgrade` 不校验版本/Origin。低优先,Origin 限制有破坏 bridge/HMR 风险,做就保持配置门控。**涉及** `SandboxServerCore.swift` · `WebSocket.swift`。

> **不做(默认):body 脱敏**〔原 P1-2〕——对调试是**反效果**(测试常常就想看到完整 token/body),且仅在不可信网络才有价值;header 脱敏已默认开启。若将来确需,可经 `SandboxConfig.redactBodyKeys` 做成**默认关闭**的可选项。

---

## F. 仅当将来要"公开发布"时(当前内部使用 → 搁置)

> 你确认是团队/组织内部使用,以下都不阻塞当前工作;若哪天要发到公共 SPM/CocoaPods/npm 再做。

- [ ] **F1** 补 MIT `LICENSE` 并打进 npm tarball(`pod lib lint`/`npm publish` 才需)〔原 P0-1, S〕
- [ ] **F2** 替换 `your-org` 占位 URL(`SandboxServer.podspec:12,15`、两个 README SPM 片段)〔原 P0-2, S〕
- [ ] **F3** `pod lib lint` 验证单模块折叠并接入 CI(依赖 F1/F2)〔原 P1-7, M〕
- [ ] **F4** MCP bridge 发布就绪:版本单一来源、npm 元数据、删 token-in-TXT 死分支〔原 P2-6, S〕
- [ ] **F5** CHANGELOG + 跨件套版本同步守卫〔原 P2-7, S〕
- [ ] **F6** SandboxServerAPI 插件作者指南(1.0.0 冻结前置)〔原 P2-8, M〕

---

## 依赖链 & 建议起手序
1. **A1**(bridge 超时,S)→ 立竿见影,先做。
2. **A3**(触摸支持,M)→ 测试真机体验,独立可并行。
3. **A4**(错误分类,M,依赖 A1)→ **A5**(自动重连,L)。
4. **A2**(WS 不卡死,M)→ 与 D2 的 WSHub 测试相邻,可一起做。
5. 体验项 **B1/B2**(都 S)随手清掉;**B3** 较大可排后。
6. 防回归 **D1 → D2**(核心契约)优先,**D5** 偏安全可最后。
7. **E/F** 整段按需,不阻塞。

## 方法学
7 个 agent(6 facet 分析 + 1 综合)读真实源码、对照 `file:line` 核实后产出;再依"内部使用 + 受信任网络 + 方便开发/测试"的定位重排。原始 P0/P1/P2 标注保留在每条 〔...〕 内以便追溯。
