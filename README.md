# Moonterm

macOS 原生 SSH 客户端。Swift + SwiftUI + AppKit，顶部多 tab，同时连接多台设备。

## 功能

- 顶部 tab，多台设备同时连接；**切换 tab 不断线**（终端视图常驻，PTY 不销毁）
- **一个 tab 固定一台主机**：tab 标题就是主机名，tab 里所有分栏都是这台主机
  - tab 条上只能**拖动排序**；tab 之间不合并，也不能拖进别的 tab 的分栏里
  - 每个分栏顶部都有一条**标题栏**：新建 tab 时那个全屏分栏就叫「窗口1」，之后新建的是「窗口2」「窗口3」…（关掉的编号会被回收复用）
  - 分栏与新建窗口都只发生在当前 tab 内：`⌘D` / `⇧⌘D` 分栏、标题栏右侧的 `+` 在本分栏里再叠一个窗口，一律用本 tab 的主机，不再问选哪台
  - 拖窗口小标签在本 tab 内重新布局：落在分栏边缘 = 开新分栏；落在正中或落在标题栏上 = 并进那个分栏，多一个小标签
  - 拖分割线调整比例；当前分栏有强调色边框
- 主机配置：名称 / 地址 / 端口 / 用户名 / 密码，本地持久化
- 完整终端体验：VT/xterm 仿真、真彩色、鼠标上报、滚动缓冲、选区复制粘贴（基于 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)）
- 断线有明确提示与失败原因（认证失败 / 端口不通 / 主机密钥变更 …），⌘R 重连
- 字号调整并记住设置

## 快捷键

| 快捷键 | 作用 |
|---|---|
| `⌘T` | 新建连接（选主机 → 新 tab） |
| `⌥⌘T` | 在当前分栏新建窗口（同主机，多一个小标签） |
| `⌘W` | 关闭当前窗口（tab 里只有一个时就是关闭标签页） |
| `⇧⌘W` | 关闭 App 窗口（系统菜单项，被挪到这里给 `⌘W` 腾位置） |
| `⌘R` | 重新连接（当前分栏） |
| `⌘D` / `⇧⌘D` | 左右分栏 / 上下分栏（同主机，直接开） |
| `⌥⌘←` `⌥⌘→` `⌥⌘↑` `⌥⌘↓` | 在分栏间移动焦点 |
| `⇧⌘]` / `⇧⌘[` | 下一个 / 上一个标签页 |
| `⌘1` … `⌘9` | 跳到第 N 个标签页 |
| `⌘+` / `⌘-` / `⌘0` | 放大 / 缩小 / 恢复字号 |
| `⌘,` | 主机管理 |

## 构建

需要 **Xcode 16 及以上**（SwiftTerm 的包清单是 `swift-tools-version:6.0`）。只装 Command Line Tools 且版本较老时无法编译。

```bash
sudo xcode-select -s /Applications/Xcode.app   # 装好 Xcode 后指过去
swift --version                                # 应 >= 6.0

bash scripts/build-app.sh                      # 产出 ./Moonterm.app
open Moonterm.app
```

开发时也可以直接 `open Package.swift` 用 Xcode 打开，或：

```bash
swift run Moonterm     # 不打包直接跑（菜单栏名称会显示为进程名）
swift test             # 跑 MoontermCore 的单测
```

## 实现方式

SSH 不自己实现协议，而是用 PTY 包装系统的 `/usr/bin/ssh`：

```
SwiftUI ─ SSHTerminalView (SwiftTerm) ─ PTY ─ /usr/bin/ssh ─ 远端
```

好处是密钥、跳板机（`ProxyJump`）、`~/.ssh/config`、known_hosts、压缩等 OpenSSH 的能力全部天然可用，也没有自研协议栈的安全风险。

密码通过 OpenSSH 的 `SSH_ASKPASS` 机制传递：

- 密码写进临时文件（创建时即 `0600`），路径经环境变量交给 `MoontermAskpass` 助手
- 设置 `SSH_ASKPASS_REQUIRE=force`，ssh 就会调助手取密码，而不是从终端读
- 密码**不出现在命令行**（`ps` 看不到），也不经过终端输入流
- 万一 askpass 没生效，会退回到「检测到 ssh 的密码提示再写入 PTY」的兜底路径；该路径只在连接后 20 秒内有效且只触发一次，避免把 SSH 密码误灌给远端的 `sudo` 提示

会话状态由 `SSHOutputMonitor` 从 ssh 的输出里归因，退出时给出中文原因。

tab 与分栏：每个 tab 是「一台主机 + 一棵分栏树」（`TerminalTab` / `PaneNode`，纯逻辑放在 MoontermCore 里单测），
叶子是一组会话（`PaneGroup`：若干会话 + 当前显示的那个，对应分栏顶部标题栏上的小标签）。
主机绑在 tab 上、窗口编号也由 tab 分配（关掉即释放，新建补最小空缺），所以会话不会跨 tab 搬动：
`DragController` 在落点判定阶段就把「tab → 分栏」和「分栏 → tab 条」两种越界拖拽判成无效。
所有 tab 的树**同时留在视图层级里**，只用透明度决定谁可见 —— 换成 `if/else` 会销毁 NSView 从而杀掉 PTY。
拖拽用 SwiftUI 的 `DragGesture` 而不是 `onDrag`/`onDrop`：起手在 tab 条或分栏子标题条上，
AppKit 会把后续鼠标事件继续投给起点视图，指针移到终端上方时不会被 SwiftTerm 的 NSView 截走。

## 配置文件

| 文件 | 内容 |
|---|---|
| `~/Library/Application Support/Moonterm/hosts.json` | 主机配置（**不含密码**），权限 `0600` |
| `~/Library/Application Support/Moonterm/secrets.json` | 密码，权限 `0600` |

> ⚠️ **密码是明文保存的。** 文件权限限制到仅本用户可读，但不受钥匙串保护 —— 本用户的任何进程都能读到。
> 这是当前版本的显式取舍。要换成钥匙串，只需实现 `SecretStore` 协议（见
> [SecretStore.swift](Sources/MoontermCore/Store/SecretStore.swift)）并在 `ConfigStore` 初始化时替换，其余代码不用改。

## 代码结构

```
Sources/MoontermCore/         纯逻辑，无 UI 依赖，有单测覆盖
  Models/HostConfig.swift     主机配置模型与校验
  Models/PaneLayout.swift     分栏树（分栏增删移、组内并入/切换、占比）与落点判定
  Models/TerminalTab.swift    一个 tab = 一台主机 + 分栏树 + 窗口编号 + 聚焦的会话
  Store/ConfigStore.swift     配置持久化（原子写 + 0600）
  Store/SecretStore.swift     密码存取抽象 + 明文实现
  SSH/SSHCommandBuilder.swift ssh argv/env 构造
  SSH/AskpassBridge.swift     临时密码文件的创建与清理
  SSH/SSHOutputMonitor.swift  失败归因 + 密码兜底注入的判定

Sources/Moonterm/             App 本体
  MoontermApp.swift           入口
  AppState.swift              会话、tab 列表、选中与聚焦、字号
  AppCommands.swift           菜单与快捷键
  AppDelegate.swift           菜单快捷键微调、退出前收尾
  SSH/SSHTerminalView.swift   LocalProcessTerminalView 子类
  SSH/SSHSession.swift        单个会话的状态机
  SSH/TerminalFocusMonitor.swift  点终端就聚焦所在分栏（窗口级鼠标监听）
  UI/PaneTreeView.swift       分栏树渲染、分割线、分栏标题栏（窗口小标签 + 新建）
  UI/DragController.swift     拖拽状态与落点判定
  UI/DropIndicatorOverlay.swift  拖拽时的落点高亮与幽灵
  UI/                         tab 条、终端容器、主机管理与编辑

Sources/MoontermAskpass/      SSH_ASKPASS 助手（独立可执行文件）
```

## 尚未支持

私钥认证的 UI（留空密码时 ssh 仍会走密钥/agent）、SFTP 文件传输、端口转发、会话分组、主题配色。
