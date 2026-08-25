# AGENTS.md

给在本仓库里干活的 AI agent 看的指南。功能说明与快捷键表在 [README.md](README.md)，这里只写**怎么动手、以及哪些地方不能乱动**。

## 项目是什么

Moonterm：macOS 原生 SSH 客户端。Swift + SwiftUI + AppKit，顶部多 tab、可分栏，同时连接多台设备。

SSH **不自己实现协议**，而是用 PTY 包装系统的 `/usr/bin/ssh`：

```
SwiftUI ─ SSHTerminalView (SwiftTerm) ─ PTY ─ /usr/bin/ssh ─ 远端
```

所以密钥、`ProxyJump`、`~/.ssh/config`、known_hosts 这些 OpenSSH 能力天然可用。**不要**引入自研 SSH 协议栈或 libssh2 之类的依赖。

## 构建与测试

工具链就绪（Xcode 26 / Swift 6.3.3，`xcode-select -p` 指向 `/Applications/Xcode.app`），改完代码**要真的跑起来验证**，不要声称无法编译。

```bash
swift build                      # 编译
swift test                       # MoontermCore 单测（UI 层没有测试）
bash scripts/build-app.sh        # 产出 ./Moonterm.app（release；传 debug 出 debug 版）
swift run Moonterm               # 不打包直接跑
```

`Package.swift` 的 `swift-tools-version` 是 6.0（跟 SwiftTerm 对齐），但 `swiftLanguageModes: [.v5]` —— 语言模式**故意**留在 v5，避免 Swift 6 严格并发检查跟 AppKit/SwiftUI 混用炸出一堆噪音。不要顺手升到 v6。

## 目录结构

```
Sources/MoontermCore/    纯逻辑，无 UI / 无 SwiftTerm 依赖，有单测覆盖
  Models/                HostConfig、HostGroup、HostSelection、PaneLayout、TerminalTab
  Store/                 ConfigStore（持久化）、SecretStore、SecureFile、MoontermPaths
  SSH/                   SSHCommandBuilder、AskpassBridge、SSHOutputMonitor
Sources/Moonterm/        App 本体（SwiftUI + AppKit + SwiftTerm）
  AppState.swift         会话、tab 列表、选中与聚焦、字号、侧栏开合与宽度
  AppCommands.swift      菜单与快捷键
  UI/                    竖栏、主机面板、tab 条、分栏树、拖拽、终端容器
  SSH/                   SSHTerminalView、SSHSession、TerminalFocusMonitor
Sources/MoontermAskpass/ SSH_ASKPASS 助手（独立可执行文件）
Tests/MoontermCoreTests/
```

**新逻辑优先放进 MoontermCore 并配单测。** 判定类代码（落点判定、选择语义、失败归因、排序）都该是不依赖 UI 的纯函数/纯值类型 —— 现有的 `PaneLayout`、`HostSelection`、`SSHOutputMonitor` 就是这个路子。MoontermCore **不能** import SwiftUI / AppKit / SwiftTerm。

## 代码约定

- **注释和文档注释一律用中文**，`// MARK: -` 分节名也是中文。
- 注释写**为什么**，不写做了什么。现有注释大量是「换成 X 会怎样」「这里不用 Y 因为 Z」这种，跟着这个密度和语气写。
- 类型/成员上的三斜线文档注释说清语义边界（nil 代表什么、空串代表什么、顺序有没有意义）。
- 访问控制：MoontermCore 里对外用的 `public`，`@Published` 用 `public private(set)` 加显式修改方法，不要开放直接改。
- 测试用 XCTest（`import XCTest` + `@testable import MoontermCore`），测试方法名英文驼峰，注释中文。

## 架构上的硬约束

改动前先确认没有踩到下面这些 —— 它们都是踩过坑之后才写成现在这样的。

1. **所有 tab 的分栏树同时留在视图层级里，只用透明度决定谁可见。** 换成 `if/else` 会销毁 NSView，进而杀掉 PTY，切 tab 就断线。
2. **拖拽用 SwiftUI 的 `DragGesture`，不用 `onDrag`/`onDrop`。** 起手在 tab 条或分栏标题条上，AppKit 会把后续鼠标事件继续投给起点视图，指针移到终端上方时不会被 SwiftTerm 的 NSView 截走。
3. **主机面板的拖拽是另一套**（`UI/HostSidebarDrag.swift`）。主机行的点击本来就要区分修饰键和点击次数，走 `ClickCatcher` 那层 NSView；mouseDown 一旦被它接下，后续 mouseDragged 只发给它，`DragGesture` 收不到 —— 点击和拖动必须从同一条 AppKit 通道报出来。
4. **主机顺序只有 `ConfigStore.hosts` 这一份数组。** 分组只是把这份顺序切成几段展示（`sections`），所以「排到某个分组末尾」等价于「排到数组末尾」。不要再引入第二份顺序。
5. **一个 tab 固定一台主机。** 主机与窗口编号都绑在 tab 上，会话不跨 tab 搬动；`DragController` 在落点判定阶段就把「tab → 分栏」「分栏 → tab 条」判成无效。
6. **askpass 助手必须和主程序同目录** —— `AskpassBridge.locateHelper()` 就是这么找的，改打包脚本时别拆开。
7. 配置文件写盘走 `SecureFile`（原子写 + `0600`），`hosts.json` 带 `version` 字段，改结构要考虑迁移（v1 没有 `groups` 字段，解出来是 nil）。

## 已定决策，不要重开

- **密码明文存 `secrets.json`（权限 0600）是用户明确的选择**，不要擅自改成钥匙串，也不要在回答里反复劝。代码里有 `SecretStore` 协议就是留好替换口子；只有用户重新提出时才实现 Keychain 版本。
- 密码通过 `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` 传给 ssh，不出现在命令行。另有一条「检测到密码提示再写入 PTY」的兜底路径，**只在连接后 20 秒内有效且只触发一次** —— 这个限制是为了不把 SSH 密码误灌给远端的 `sudo` 提示，不要放宽。
- 选主机只有左侧主机面板这一处入口：tab 条上没有 `+`，`⌘T` 就是展开那个面板。

## 跑 App 做界面验证的坑

能用 `swift test` 覆盖的就别开 GUI。真要跑界面：

- **没法用 `HOME=/tmp/...` 隔离配置**：`FileManager.urls(for: .applicationSupportDirectory)` / `NSHomeDirectory()` 取的是 getpwuid 的家目录，无视 `HOME`，调试实例读写的是用户**真实**的 `hosts.json` / `secrets.json`。要做会写盘的操作（新建分组、改配置）之前先把这两个文件备份到 /tmp，验证完立刻还原。
- **AppleScript 按 pid 找进程会误伤用户的实例**：`first process whose unix id is <pid>` 在同名进程下会拿到另一个。可靠写法是 `repeat with p in (every process whose name is "…")` 再 `if (unix id of p) is <pid> then …`。动窗口位置前先记下原来的 position/size。
- **裸二进制 `.build/debug/Moonterm` 无法激活到前台**，收不到 keystroke。要发键就拷进一个临时 bundle（`/tmp/XxxDemo.app/...` + `codesign -s -`，名字**故意和真 App 不同**方便按进程名区分），直接跑 bundle 里的可执行文件（这样 stderr 还能重定向到文件；用 `open -a` 拿不到日志）。发键前必须校验前台进程的 unix id 是自己那个。
- 截图用 `CGWindowListCopyWindowInfo` 按 ownerPID 找 window id 再 `screencapture -l <id>`，**不要全屏截图**（会拍到用户的桌面）。
- **合成鼠标拖拽这台机器做不到**（没有 python Quartz、没有 cliclick，System Events 不支持 drag），拖拽类交互只能请用户自己试。
- 需要造出 tab / 分栏这类得点击才有的状态，可以临时在 `MoontermApp.onAppear` 里按 `--ui-demo` 启动参数直接调 `appState.open(host:)`（假主机指 `127.0.0.1:1`，不碰真机器），验证完 `git checkout` 掉。

## 沟通

用中文回答。
