# AGENTS.md

给在本仓库工作的 AI agent。功能、快捷键、实现原理和完整目录见 [README.md](README.md)；这里只保留动手规范与不可破坏的边界。

## 开始前

Moonterm 是 Swift + SwiftUI + AppKit 的 macOS 原生 SSH 客户端。SSH 通过 PTY 包装系统的 `/usr/bin/ssh`，不要引入自研 SSH 协议栈或 libssh2。

工具链已就绪（Xcode 26 / Swift 6.3.3）。改完必须实际验证：

```bash
swift build                 # 编译
swift test                  # MoontermCore 单测
bash scripts/build-app.sh   # 产出 ./Moonterm.app；传 debug 构建调试版
swift run Moonterm          # 不打包运行
```

`Package.swift` 的 tools version 是 6.0，但 `swiftLanguageModes: [.v5]` 是有意保留的；不要升级到 Swift 6 语言模式。

## 代码落点与风格

- 新逻辑优先放进 `Sources/MoontermCore/` 并配 XCTest。落点、选择、排序、失败归因等判定应写成纯函数或纯值类型。
- MoontermCore 不能 import SwiftUI、AppKit 或 SwiftTerm；UI 与会话代码放在 `Sources/Moonterm/`。
- 注释、文档注释和 `// MARK: -` 分节名一律用中文。注释解释“为什么”；文档注释说清 nil、空串、顺序等语义边界。
- MoontermCore 对外 API 用 `public`；`@Published` 用 `public private(set)` 配显式修改方法，不开放直接写入。
- 测试用 `import XCTest` + `@testable import MoontermCore`，方法名用英文驼峰，注释用中文。

## 不可破坏的边界

### 会话与界面

1. **所有 tab 的分栏树必须同时留在视图层级里，只用透明度切换。** `if/else` 会销毁 NSView 和 PTY，导致切 tab 断线。
2. **tab / 分栏拖拽使用 SwiftUI `DragGesture`，不用 `onDrag` / `onDrop`。** 主机面板例外：它必须继续走 `UI/HostSidebarDrag.swift` 与 `ClickCatcher` 的同一条 AppKit 鼠标通道。
3. **主机顺序只有 `ConfigStore.hosts` 一份。** 分组只是切分这份数组，不要引入第二份顺序。
4. **一个 tab 固定一台主机。** 会话不跨 tab 移动；`DragController` 必须继续拒绝 tab 与分栏之间的越界落点。
5. **分隔线光标必须走 `PaneDividerCursorGuard`。** T / 十字接点判定以交点为原点，不能以鼠标位置为原点。
6. **删除确认使用 `DestructiveConfirmation.swift`，不要换回系统 `.alert`。**
   - 所有淡入淡出路径都经过 `ConfirmationCenter.ask/confirm/cancel`。
   - 只显示一行标题；标题在弹出时固定为 `DestructiveConfirmationRequest` 值，不能随数据变化。
   - 弹窗挂在窗口或整张 sheet 的最外层；主机管理窗口单独持有 `ConfirmationCenter`。
   - `ConfirmationModalGuard` 负责拦截本窗口内非 ⌘ 按键及弹窗外点击/滚动，但放行标题栏。
   - 破坏性按钮不要加 `.keyboardShortcut(.defaultAction)`；Enter / Esc 由 guard 处理。

### SSH、SFTP 与持久化

1. `MoontermAskpass` 必须和主程序同目录，`AskpassBridge.locateHelper()` 依赖这一布局。
2. 文件面板只复用当前会话的 `SSHSession.controlPath`，不能按主机共享。sftp 固定使用 `ControlMaster=no` + `BatchMode=yes`，只复用、不新建、不提问。
3. 列目录必须用 `ls -lan`；`SFTPListingParser` 依赖 `-n` 产生的固定格式。
4. sftp 必须把 UTF-8 `LC_ALL` 叠加到继承环境，不能整套替换环境，否则会丢失 `HOME`。
5. sftp 路径参数只转义 `\` 和 `"`；双引号已经关闭 glob，不要额外转义 `*`、`?`、`[`。
6. 批处理命令不要加 sftp 的 `-` 前缀；默认“一错即退”的退出码才是可信失败信号。
7. 配置写盘统一走 `SecureFile`（原子写 + `0600`）。`hosts.json` 带 `version`，结构变化必须兼容迁移；v1 没有 `groups` 字段。

## 已定决策

- 密码明文存入权限为 `0600` 的 `secrets.json` 是用户明确选择。除非用户重新提出，不要改成 Keychain，也不要反复劝告。
- 密码通过 `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` 传递，不进入命令行。PTY 密码提示兜底只允许连接后 20 秒内触发一次，不能放宽，以免误灌给远端 `sudo`。
- 选主机只有左侧主机面板这一处入口；tab 条没有 `+`，`⌘T` 用于展开主机面板。

## 验证注意事项

SFTP 的引号、输出格式和批处理分帧可由 `SFTPRunnerLocalTests` 通过本机 sftp-server 验证，无需远端：

```bash
printf 'ls -lan "/tmp"\n' | sftp -q -b - -D /usr/libexec/sftp-server
```

认证与 ControlMaster 复用仍需真实 sshd。若临时使用本机 `127.0.0.1` sshd，完成后清理临时密钥和对应 `known_hosts` 条目；不要用会覆盖 `known_hosts.old` 的 `ssh-keygen -R`。

能用单测覆盖时不要启动 GUI。必须做界面验证时：

- `HOME=/tmp/...` 无法隔离应用配置；写配置前备份真实 `hosts.json` / `secrets.json`，验证后立即恢复。
- 不要按进程名或模糊 PID 操作窗口；临时 bundle 使用与正式 App 不同的名字，并校验前台进程 PID。
- 截图只按 ownerPID 获取目标窗口，不截全屏。移动过的鼠标和改过的剪贴板都要恢复。
- 当前环境不能合成拖拽或右键菜单，只能请用户验证；普通点击可用临时 Swift + CGEvent 工具。
- 不要用 AppleScript `keystroke` 输入长字符串；使用 `pbcopy` + `⌘V`，随后恢复剪贴板。

## 沟通

用中文回答。
