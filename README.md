# Moonterm

macOS 原生 SSH 客户端。Swift + SwiftUI + AppKit，顶部多 tab，同时连接多台设备。

## 功能

**侧边栏**：最左边一条常驻功能竖栏（类似 VS Code），三个图标 —— 主机、文件、监控。点开在右边展开对应面板并占布局空间（终端跟着被挤窄并 reflow），边缘可拖着改宽度，宽度和上次展开的是哪个面板都记住。

**主机面板**（`⌘B`）

- 单击选中、双击连接（每次双击都是新 tab）；`⌘` 点加减、`⇧` 点扩选，点下方空白取消选中
- 右键菜单：批量连接 / 删除；单选时还有编辑、复制、移到分组（只列真能去的分组）
- 分组排在上面、未分组垫在最下面；点标题折叠（状态记住），右键可改名、在此分组新建主机、删除分组（里面的主机不删，移到未分组末尾）
- 拖动排序：组内换位、拖进别的分组、拖到最下面变未分组；拖到分组标题上 = 整片放进该分组；拖已选中的主机 = 整片选区一起搬；拖分组标题 = 连里面的主机一起搬
- 选主机只有这一处入口，tab 条上没有 `+`

**文件面板**（`⇧⌘B`）：当前 tab 那台主机的远端文件，树形浏览 + 上传下载。

- 复用终端那条已连上的 ssh 连接（ControlMaster 多路复用），不会再问密码，一次往返只有几十毫秒
- 自动定位到终端当前目录（OSC 7 优先，其次 xterm 标题，都没有就家目录），默认跟随 `cd`，可在 `…` 菜单关掉
- 树根是当前目录而不是 `/`；顶部面包屑可跳转，右键目录可「作为根目录打开」
- 单击目录展开、单击文件只选中 —— 双击文件不会开始下载
- 下载走右键菜单（文件夹用 `get -rp`）；上传点标题栏按钮或目录右键菜单，可多选、可传整个文件夹（`put -rp`），落点是当前选中的目录
- 底部传输区：普通文件上传、下载都有百分比；目录传输显示不确定进度；可取消、可清除已完成，同时最多两个，其余排队
- `…` 菜单：显示隐藏文件（只是过滤，不重新列目录）、跟随终端目录

**监控面板**（`⌥⌘B`）：当前 tab 那台主机的 CPU / 内存 / 磁盘 / 负载 / 网络，只读 `/proc` 和跑 `df`，远端不用装任何东西。

- 同样复用终端那条已连上的 ssh 连接，不会再问密码
- CPU / 内存 / 负载 / 网络画小折线（从右往左长出来，最近 120 次采样）；网络下载与上传分成两块，各自显示当前速率和历史峰值
- 磁盘不画折线（两秒一采的曲线是条直线），每个挂载点一条占比条；根分区排最前，其余按使用率从高到低最多留 4 条；到 90% 变红并加警示图标
- 采样间隔可选 1 / 2 / 5 秒，也能暂停（暂停不清历史）；**面板收起就停止采样**，不在后台偷跑
- 只支持 Linux 远端（指标全在 `/proc` 里）；远端没有 `/proc` 时面板直接说明，不空着让人以为是坏了

**Tab 与分栏**

- 切换 tab 不断线（终端视图常驻，PTY 不销毁）
- 一个 tab 固定一台主机：tab 标题就是主机名，tab 里所有分栏都是这台主机
- tab 条上只能拖动排序：被拖的 tab 跟指针走，其余实时滑开让位；tab 之间不合并、不能拖进别的 tab
- 每个分栏顶部有标题栏，窗口默认叫「窗口1」「窗口2」…（关掉的编号回收复用），双击小标签 / `⇧⌘R` 可改名
- `⌘D` / `⇧⌘D` 分栏，`⌘T` 或标题栏 `+` 在本分栏再叠一个窗口，一律用本 tab 的主机
- 拖窗口小标签重新布局：落在分栏边缘 = 开新分栏，落在正中或标题栏 = 并进那个分栏
- 拖分割线调整比例；当前分栏有一圈暗蓝色边框（落点框同色）
- tab 和窗口小标签上按中键即关闭

**其他**

- 主机配置：名称 / 地址 / 端口 / 用户名 / 密码 / 分组，本地持久化
- 完整终端体验：VT/xterm 仿真、真彩色、鼠标上报、滚动缓冲、选区复制粘贴（基于 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)）
- 终端里选中即复制、右键即粘贴（⌘C / ⌘V 照旧可用）
- 断线有明确提示与失败原因（认证失败 / 端口不通 / 主机密钥变更 …），⌘R 重连
- 字号调整并记住设置

## 快捷键

| 快捷键 | 作用 |
|---|---|
| `⌘T` | 在当前分栏新建窗口（同主机，多一个小标签） |
| `⌘B` | 显示 / 隐藏主机面板 |
| `⇧⌘B` | 显示 / 隐藏文件面板 |
| `⌥⌘B` | 显示 / 隐藏监控面板 |
| `⌘W` | 关闭当前窗口（tab 里只有一个时就是关闭标签页） |
| `⇧⌘W` | 关闭 App 窗口（系统菜单项，被挪到这里给 `⌘W` 腾位置） |
| `⌘R` | 重新连接（当前分栏） |
| `⇧⌘R` | 重命名当前分栏 |
| `⌘D` / `⇧⌘D` | 左右分栏 / 上下分栏（同主机，直接开） |
| 主机面板中的 `⌘D` | 复制当前选中的主机 |
| `⌥⌘←` `⌥⌘→` `⌥⌘↑` `⌥⌘↓` | 在分栏间移动焦点 |
| `⇧⌘]` / `⇧⌘[` | 下一个 / 上一个标签页 |
| `⌘1` … `⌘9` | 跳到第 N 个标签页 |
| `⌘+` / `⌘-` / `⌘0` | 放大 / 缩小 / 恢复字号 |
| `⌘,` | 主机管理面板（排序、批量管理这些低频操作） |
| 删除确认弹窗中的 `⏎` / `esc` | 确认删除 / 取消（点弹窗外面也是取消） |

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

### SSH

不自己实现协议，用 PTY 包装系统的 `/usr/bin/ssh`：

```
SwiftUI ─ SSHTerminalView (SwiftTerm) ─ PTY ─ /usr/bin/ssh ─ 远端
```

密钥、跳板机（`ProxyJump`）、`~/.ssh/config`、known_hosts、压缩等 OpenSSH 的能力全部天然可用，也没有自研协议栈的安全风险。

密码通过 `SSH_ASKPASS` 传递：写进临时文件（创建时即 `0600`），路径经环境变量交给 `MoontermAskpass` 助手，配合 `SSH_ASKPASS_REQUIRE=force` 让 ssh 调助手取密码。于是密码不出现在命令行（`ps` 看不到），也不经过终端输入流。万一 askpass 没生效，会退回到「检测到 ssh 的密码提示再写入 PTY」的兜底路径；该路径只在连接后 20 秒内有效且只触发一次，避免把 SSH 密码误灌给远端的 `sudo` 提示。

会话状态由 `SSHOutputMonitor` 从 ssh 的输出里归因，退出时给出中文原因。

### SFTP

文件面板同样用系统的 `/usr/bin/sftp`：

```
FileSidebarView ─ RemoteFileBrowser ─ SFTPRunner ─ /usr/bin/sftp ─┐
                                                                 ├─ 同一条 ssh 连接
终端 SSHTerminalView ─ PTY ─ /usr/bin/ssh ─ ControlMaster socket ─┘
```

- 终端那条 ssh 带 `-o ControlMaster=auto -o ControlPath=<socket>`，socket 每个会话一份（不是每台主机一份 —— 共享的话当 master 的那个分栏一断，同主机其他分栏会跟着掉）
- sftp 带 `-o ControlMaster=no -o ControlPath=<同一个 socket> -o BatchMode=yes`：只复用、不新建、绝不交互提问。认证只在终端连接那一次发生，面板全程不碰密码；master 不在时立刻失败而不是挂住
- 列目录用 `ls -lan`，`-n` 不能去掉：不带它 sftp 打印的是服务端给的 longname（格式随实现变），带上才是客户端本地格式化的固定格式，`SFTPListingParser` 就照那个写的
- sftp 进程强制 `LC_ALL=en_US.UTF-8`：否则非 ASCII 名字会被按八进制转义打出来（`中文.txt` → `\344\270\255\346\226\207.txt`），转义后的名字拿回去 `get` 找不到文件。从 `.app` 启动时环境里本来就没有 `LANG`
- 一次调用可跑多条命令，靠 sftp 自己打的 `sftp> <命令>` 回显行切分输出；批处理「一错即退」的默认行为故意保留，这样退出码就是可信的失败信号

三条已知限制：

- **传输百分比**：sftp 批处理模式没有进度事件，下载用本地落地文件大小推算，普通文件上传则通过当前会话的 ControlMaster 定时查询远端目标大小；目录传输无法用单个大小可靠表示，保持不确定进度
- **当前目录只能猜**：ssh 是被 PTY 包起来的黑盒，只能看远端主动吐出的 OSC 7 或标题；两样都不发时停在家目录
- **ssh-agent 用不上**：`SSH_AUTH_SOCK` 不在 SwiftTerm 传给子进程的环境里，密钥认证只能靠 `~/.ssh` 下的文件

### 监控采集

监控面板不装 agent、也不每隔两秒起一次 ssh，而是**常驻一条流**：

```
MonitorSidebarView ─ HostMonitor ─ RemoteMetricsStream ─ /usr/bin/ssh ─┐
                                                                      ├─ 同一条 ssh 连接
终端 SSHTerminalView ─ PTY ─ /usr/bin/ssh ─ ControlMaster socket ──────┘
```

- 复用方式和 sftp 完全一样（`ControlMaster=no` + 同一个 socket + `BatchMode=yes`），另加 `-T`：只要一条干净的字节流，不要 tty
- 远端命令只有 `sh -s`，**脚本从 stdin 灌进去**（`RemoteMetricsScript`）。脚本里全是引号和 `$`，拼进命令行就得为「本地 argv → 远端登录 shell」逐层转义两遍，而登录 shell 还可能是 csh 或 fish
- 脚本自己循环：`while :; do 读一圈 /proc; df -kP; echo '#m:end'; sleep N; done`。于是只握手一次，采样间隔由远端的 `sleep` 决定，不受本地调度和网络抖动影响
- 本地按 `#m:end` 这一行分帧（`RemoteMetricsStream`），逐帧解析（`RemoteMetricsParser`）。某一节坏了只丢那一节，不会让图断一格
- 时间轴取 `/proc/uptime` 而不是 `date +%s`：它是单调的（不被改系统时间或 NTP 跳秒带偏），精度 0.01 秒；变小就说明远端重启了，那时清掉历史重新开始
- CPU 占用和网络速率都是**两帧之差**（`HostMetricsFrame.sample(previous:)`）：第一帧、时间差为 0、计数器变小时一律给 nil，不回填 0 —— 图上凭空的一段平地比一段空白更难发现问题
- 内存已用取 `MemTotal - MemAvailable`（不是 `- MemFree`）：Linux 把空闲内存全拿去当页缓存，按 free 算永远是 99%
- CPU 的 `iowait` 算闲着：那段时间 CPU 真没在算东西，等的是磁盘；算进忙的话一台在拷文件的机器会显示满载
- 网络排掉 `lo` 与 `docker*` / `veth*` / `br-*` 这些虚拟口，剩下的相加：容器宿主上它们会把同一份流量再数一遍

整条链路（起进程 → 灌脚本 → 分帧 → 解析 → 差分）都能在本机验证，不需要远端：`RemoteMetricsScript.script(procRoot:)` 可以把 `/proc` 指到一个装了假 `stat` / `meminfo` 的临时目录，让本机 `/bin/sh` 当远端 shell（见 `RemoteMetricsStreamLocalTests`）。

### Tab 与分栏

每个 tab 是「一台主机 + 一棵分栏树」（`TerminalTab` / `PaneNode`，纯逻辑在 MoontermCore 里单测），叶子是一组会话（`PaneGroup`，对应标题栏上的小标签）。主机绑在 tab 上、窗口编号也由 tab 分配，所以会话不会跨 tab 搬动：`DragController` 在落点判定阶段就把越界拖拽判成无效。

所有 tab 的树同时留在视图层级里，只用透明度决定谁可见 —— 换成 `if/else` 会销毁 NSView 从而杀掉 PTY。拖拽用 `DragGesture` 而不是 `onDrag`/`onDrop`：起手在 tab 条或分栏标题条上，AppKit 会把后续鼠标事件继续投给起点视图，指针移到终端上方时不会被 SwiftTerm 截走。

主机面板的拖拽是另一套（`HostSidebarDrag.swift`）：主机行的点击本来就要修饰键和点击次数，走 `ClickCatcher` 那层 NSView；mouseDown 一旦被它接下，后续 mouseDragged 就只发给它，`DragGesture` 收不到 —— 点击和拖动必须从同一条 AppKit 通道报出来。分组顺序在 `ConfigStore.groups`，主机顺序只有 `ConfigStore.hosts` 这一份数组：分组只是把它切成几段展示，所以「排到某个分组末尾」等于「排到数组末尾」。

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
  Models/HostMetrics.swift    一帧原始读数（/proc 的累计计数）+ 两帧差分出来的一格样本
  Models/MetricHistory.swift  定长滑动历史（小折线图的数据源）
  Store/ConfigStore.swift     配置持久化（原子写 + 0600）、分组增删改、拖动排序
  Store/SecretStore.swift     密码存取抽象 + 明文实现
  SSH/SSHCommandBuilder.swift ssh argv/env 构造（含 ControlMaster socket）
  SSH/AskpassBridge.swift     临时密码文件的创建与清理
  SSH/SSHOutputMonitor.swift  失败归因 + 密码兜底注入的判定
  SSH/SFTPCommandBuilder.swift  sftp argv、批处理脚本、引号规则、按回显行分帧
  SSH/SFTPListingParser.swift   解析 sftp `ls -lan` 的输出
  SSH/RemoteCwdParser.swift     从 OSC 7 / xterm 标题里猜远端当前目录
  SSH/SFTPRunner.swift          跑一次 sftp（进程、超时、取消；一次性对象）
  SSH/RemoteShellCommandBuilder.swift  在远端跑一段 shell 脚本的 ssh argv（脚本走 stdin）
  SSH/RemoteMetricsScript.swift  监控采集脚本（远端自己循环）+ 分帧标记
  SSH/RemoteMetricsParser.swift  解析 /proc 与 df -kP 的输出
  SSH/RemoteMetricsStream.swift  跑一条常驻采集流（起进程、按帧交付、停）

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
  UI/MonitorSidebarView.swift 竖栏展开的监控面板（折线 / 占比条 / 配色与数字格式）
  UI/HostMonitor.swift        监控面板的状态：采集流、滑动历史、暂停与间隔（一个 tab 一份）
  UI/SidebarPlaceholder.swift 没有打开的连接时，文件面板与监控面板共用的占位
  UI/PaneTreeView.swift       分栏树渲染、分割线、分栏标题栏（窗口小标签 + 新建）
  UI/DragController.swift     tab 与分栏的拖拽状态与落点判定
  UI/DropIndicatorOverlay.swift  拖拽时的落点高亮与幽灵
  UI/ClickCatcher.swift       中键点击、带修饰键与点击次数的左键点击、左键拖动（回 AppKit 接）
  UI/                         tab 条、终端容器、主机管理与编辑

Sources/MoontermAskpass/      SSH_ASKPASS 助手（独立可执行文件）
```
