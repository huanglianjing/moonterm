# Moonterm

macOS 原生 SSH 客户端。Swift + SwiftUI + AppKit，顶部多 tab，同时连接多台设备。

## 功能

- 最左边一条常驻**功能竖栏**（类似 VS Code）：两个图标 —— 主机、文件。点开在右边展开对应面板，**占布局空间**（终端跟着被挤窄并 reflow），再点收起，`⌘B` / `⇧⌘B` 也能开关；边缘可拖着改宽度，宽度与展开的是哪个面板都记住
  - 主机面板里**单击选中、双击连接**（每次双击都是一个新 tab，同一台开好几个也行）；`⌘` 点单独加减、`⇧` 点整段扩选，点列表下方的空白取消全部选中；右键菜单可**批量连接或删除**选中的那几台
  - 单选时右键菜单还有编辑 / 复制 / 删除；「移到分组」只列**真能去**的地方：还没建过分组时是一条灰着的「未创建分组」，选中的几台都在同一段里时那一段不出现，分散在不同段时全都列出来
  - 面板顶部的 `+` 分成「添加主机」和「添加分组」
  - **分组**：分组一律排在上面，未分组的主机垫在最下面；点分组标题折叠/展开（折叠状态记住），右键可改名、在此分组新建主机、删除分组（**里面的主机不会跟着删**，会移到未分组末尾）
  - **拖动排序**：拖主机可以在组内换位置、拖进别的分组、拖到列表最下面变成未分组；拖到分组标题上 = 整片放进那个分组（分组行会整行高亮），其余落点画一条插入线。拖一台已经选中的主机 = 整片选区一起搬；拖分组标题 = 连里面的主机一起换位置
  - 新建的主机一律排到最下面（选了分组就是该分组的末尾）
  - 选主机只有这一处：tab 条上没有 `+`，`⌘T` 就是把这个面板展开
- **文件面板**（竖栏第二个图标，`⇧⌘B`）：当前标签页那台主机的远端文件，树形浏览 + 上传下载。全程**复用终端那条已经连上的 ssh 连接**（OpenSSH 的 ControlMaster 多路复用），所以不会再问一次密码，一次操作的往返只有几十毫秒
  - **自动定位到终端当前目录**：优先认远端发的 OSC 7（`\e]7;file://host/path`），没有就从 xterm 标题里解析（Debian / Ubuntu 的 bash 默认 PS1 自带 `\u@\h: \w`），两者都没有就落在家目录。默认**跟随**终端 `cd`，可在 `…` 菜单里关掉
  - 树根是**当前目录**而不是 `/`（侧栏窄，从根一级级缩进名字就没地方了）；顶部面包屑点哪一段就跳过去，右键目录可「作为根目录打开」
  - 单击目录展开/折叠，单击文件只选中 —— **双击文件不会开始下载**（5 GB 的文件不该因为手抖多点一下就传起来）
  - 下载走右键菜单：文件弹保存框，文件夹选一个本地目录放进去（`get -rp`）。上传点标题栏的上传按钮或目录的右键菜单，可多选、可选整个文件夹（`put -rp`），落点是**当前选中的目录**（选中文件时用它所在目录，什么都没选就是树根）
  - 面板底部是传输区：下载有百分比，上传只显示「传输中」（原因见下），可取消、可清除已完成；同时最多传两个，其余排队
  - `…` 菜单里有「显示隐藏文件」和「跟随终端目录」；隐藏文件一直都取回来了，切换只是过滤，不会重新列目录
- 顶部 tab，多台设备同时连接；**切换 tab 不断线**（终端视图常驻，PTY 不销毁）
- **一个 tab 固定一台主机**：tab 标题就是主机名，tab 里所有分栏都是这台主机
  - tab 条上只能**拖动排序**：被拖的 tab 跟着指针走，其余的实时滑开让位（不画插入线）；tab 之间不合并，也不能拖进别的 tab 的分栏里
  - 每个分栏顶部都有一条**标题栏**：新建 tab 时那个全屏分栏就叫「窗口1」，之后新建的是「窗口2」「窗口3」…（关掉的编号会被回收复用）
  - 分栏可以**改名**：双击小标签（或右键「重命名…」、`⇧⌘R`）就地编辑，回车确认、Esc 取消、清空恢复「窗口N」
  - 分栏与新建窗口都只发生在当前 tab 内：`⌘D` / `⇧⌘D` 分栏、标题栏右侧的 `+` 在本分栏里再叠一个窗口，一律用本 tab 的主机，不再问选哪台
  - 拖窗口小标签在本 tab 内重新布局：落在分栏边缘 = 开新分栏；落在正中或落在标题栏上 = 并进那个分栏，多一个小标签
  - 拖分割线调整比例；当前分栏有一圈暗蓝色边框（拖拽时的落点框用同一个暗蓝）
  - tab 和窗口小标签上**按中键即关闭**（等于点那个 ✕）
- 主机配置：名称 / 地址 / 端口 / 用户名 / 密码 / 分组（可以不选），本地持久化
- 完整终端体验：VT/xterm 仿真、真彩色、鼠标上报、滚动缓冲、选区复制粘贴（基于 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)）
- 终端里**选中即复制、右键即粘贴**（⌘C / ⌘V 照旧可用）
- 断线有明确提示与失败原因（认证失败 / 端口不通 / 主机密钥变更 …），⌘R 重连
- 字号调整并记住设置

## 快捷键

| 快捷键 | 作用 |
|---|---|
| `⌘T` | 新建连接（展开左侧主机面板，点一台就连） |
| `⌘B` | 显示 / 隐藏主机面板 |
| `⇧⌘B` | 显示 / 隐藏文件面板 |
| `⌥⌘T` | 在当前分栏新建窗口（同主机，多一个小标签） |
| `⌘W` | 关闭当前窗口（tab 里只有一个时就是关闭标签页） |
| `⇧⌘W` | 关闭 App 窗口（系统菜单项，被挪到这里给 `⌘W` 腾位置） |
| `⌘R` | 重新连接（当前分栏） |
| `⇧⌘R` | 重命名当前分栏 |
| `⌘D` / `⇧⌘D` | 左右分栏 / 上下分栏（同主机，直接开） |
| `⌥⌘←` `⌥⌘→` `⌥⌘↑` `⌥⌘↓` | 在分栏间移动焦点 |
| `⇧⌘]` / `⇧⌘[` | 下一个 / 上一个标签页 |
| `⌘1` … `⌘9` | 跳到第 N 个标签页 |
| `⌘+` / `⌘-` / `⌘0` | 放大 / 缩小 / 恢复字号 |
| `⌘,` | 主机管理面板（排序、批量管理这些低频操作） |

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

文件面板同样不自己实现协议，用的是系统的 `/usr/bin/sftp`：

```
FileSidebarView ─ RemoteFileBrowser ─ SFTPRunner ─ /usr/bin/sftp ─┐
                                                                 ├─ 同一条 ssh 连接
终端 SSHTerminalView ─ PTY ─ /usr/bin/ssh ─ ControlMaster socket ─┘
```

- 终端那条 ssh 带上 `-o ControlMaster=auto -o ControlPath=<socket>`，socket 是**每个会话一份**
  （不是每台主机一份 —— 共享的话当 master 的那个分栏一断，同主机其他分栏会跟着一起掉）
- 文件面板的 sftp 带 `-o ControlMaster=no -o ControlPath=<同一个 socket> -o BatchMode=yes`：
  只复用、不新建、绝不交互提问。于是**认证只在终端连接那一次发生**，面板全程不碰密码；
  master 不在时它会立刻失败而不是挂住
- 列目录用 `ls -lan`，`-n` **不能去掉**：不带它 sftp 打印的是服务端给的 longname（格式随服务端实现变），
  带上才是 sftp 客户端本地格式化的固定格式，`SFTPListingParser` 就照那个格式写的
- sftp 进程强制 `LC_ALL=en_US.UTF-8`：否则非 ASCII 的名字会被按八进制转义打出来
  （`中文.txt` → `\344\270\255\346\226\207.txt`），而转义后的名字拿回去 `get` 是找不到文件的。
  从 `.app` 启动时环境里本来就没有 `LANG`，不能指望继承
- 一次调用可以跑多条命令，靠 sftp 自己打的 `sftp> <命令>` 回显行把输出切开；批处理模式「一错即退」
  的默认行为**故意保留**，这样退出码就是可信的失败信号

三条已知限制：

- **上传没有百分比**：sftp 的进度条只在 stdout 是 tty 时才输出，批处理模式下一个字都没有。
  下载的百分比是自己算的（本地落地文件当前多大 ÷ 远端说它多大），上传没有对应的东西可量
- **当前目录只能猜**：ssh 是被 PTY 包起来的黑盒，只能看远端主动吐出来的 OSC 7 或标题。
  远端两样都不发时，面板停在家目录，需要自己点
- ssh-agent 用不上（`SSH_AUTH_SOCK` 不在 SwiftTerm 传给子进程的环境变量里），密钥认证只能靠 `~/.ssh` 下的文件

tab 与分栏：每个 tab 是「一台主机 + 一棵分栏树」（`TerminalTab` / `PaneNode`，纯逻辑放在 MoontermCore 里单测），
叶子是一组会话（`PaneGroup`：若干会话 + 当前显示的那个，对应分栏顶部标题栏上的小标签）。
主机绑在 tab 上、窗口编号也由 tab 分配（关掉即释放，新建补最小空缺），所以会话不会跨 tab 搬动：
`DragController` 在落点判定阶段就把「tab → 分栏」和「分栏 → tab 条」两种越界拖拽判成无效。
所有 tab 的树**同时留在视图层级里**，只用透明度决定谁可见 —— 换成 `if/else` 会销毁 NSView 从而杀掉 PTY。
拖拽用 SwiftUI 的 `DragGesture` 而不是 `onDrag`/`onDrop`：起手在 tab 条或分栏子标题条上，
AppKit 会把后续鼠标事件继续投给起点视图，指针移到终端上方时不会被 SwiftTerm 的 NSView 截走。

主机面板的拖拽是另一套（`HostSidebarDrag.swift`）：主机行的点击本来就要修饰键和点击次数，
走的是 `ClickCatcher` 那层 NSView；mouseDown 一旦被它接下，后续 mouseDragged 就只发给它，
`DragGesture` 再也收不到 —— 所以点击和拖动必须从同一条 AppKit 通道报出来。
分组顺序在 `ConfigStore.groups`，主机顺序只有 `ConfigStore.hosts` 这一份数组：
分组只是把这份顺序切成几段展示，所以「排到某个分组末尾」就等于「排到数组末尾」。

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
  Models/HostGroup.swift      主机分组（名字 + 折叠状态；成员关系由 HostConfig.groupID 单向指过来）
  Models/HostSelection.swift  主机列表的多选语义（重选 / ⌘ 加减 / ⇧ 扩选 / 右键作用范围）
  Models/PaneLayout.swift     分栏树（分栏增删移、组内并入/切换、占比）与落点判定
  Models/TerminalTab.swift    一个 tab = 一台主机 + 分栏树 + 窗口编号 + 聚焦的会话
  Models/RemotePath.swift     远端 POSIX 路径的拼接/拆解（不走 URL 那套本地文件系统规矩）
  Models/RemoteFileEntry.swift  远端目录里的一项（类型 / 大小 / 权限 / 时间原文）
  Store/ConfigStore.swift     配置持久化（原子写 + 0600）、分组增删改、拖动排序
  Store/SecretStore.swift     密码存取抽象 + 明文实现
  SSH/SSHCommandBuilder.swift ssh argv/env 构造（含 ControlMaster socket）
  SSH/AskpassBridge.swift     临时密码文件的创建与清理
  SSH/SSHOutputMonitor.swift  失败归因 + 密码兜底注入的判定
  SSH/SFTPCommandBuilder.swift  sftp argv、批处理脚本、引号规则、按回显行分帧
  SSH/SFTPListingParser.swift   解析 sftp `ls -lan` 的输出
  SSH/RemoteCwdParser.swift     从 OSC 7 / xterm 标题里猜远端当前目录
  SSH/SFTPRunner.swift          跑一次 sftp（进程、超时、取消；一次性对象）

Sources/Moonterm/             App 本体
  MoontermApp.swift           入口
  AppState.swift              会话、tab 列表、选中与聚焦、字号、侧栏开合与宽度
  AppCommands.swift           菜单与快捷键
  AppDelegate.swift           菜单快捷键微调、退出前收尾
  SSH/SSHTerminalView.swift   LocalProcessTerminalView 子类（选中即复制、右键即粘贴）
  SSH/SSHSession.swift        单个会话的状态机
  SSH/TerminalFocusMonitor.swift  点终端就聚焦所在分栏（窗口级鼠标监听）
  UI/ActivityBarView.swift    最左侧功能竖栏与它上面的图标（SidebarPanel 枚举在这里）
  UI/HostSidebarView.swift    竖栏展开的主机面板（分组 / 选择 / 连接 / 就地改名）+ 可拖的宽度把手
  UI/HostSidebarDrag.swift    主机面板的拖拽状态、落点判定与插入线（和 tab / 分栏那套分开）
  UI/FileSidebarView.swift    竖栏展开的文件面板（面包屑 / 文件树 / 传输区）
  UI/RemoteFileBrowser.swift  文件面板的状态：看哪个目录、展开了哪几支、传输队列（一个 tab 一份）
  UI/PaneTreeView.swift       分栏树渲染、分割线、分栏标题栏（窗口小标签 + 新建）
  UI/DragController.swift     tab 与分栏的拖拽状态与落点判定
  UI/DropIndicatorOverlay.swift  拖拽时的落点高亮与幽灵
  UI/ClickCatcher.swift       中键点击、带修饰键与点击次数的左键点击、左键拖动（回 AppKit 接）
  UI/                         tab 条、终端容器、主机管理与编辑

Sources/MoontermAskpass/      SSH_ASKPASS 助手（独立可执行文件）
```

## 尚未支持

私钥认证的 UI（留空密码时 ssh 仍会走 `~/.ssh` 下的密钥，但用不了 agent）、端口转发、会话分组、主题配色。

本地ssh

监控

配置文件导出导入

主题颜色

一键多分栏布局

快捷键
