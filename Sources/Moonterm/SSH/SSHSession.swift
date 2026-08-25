import AppKit
import Combine
import Foundation
import MoontermCore
import SwiftTerm

/// 一个 tab 背后的 SSH 会话：持有终端视图 + 底层 ssh 进程 + 连接状态。
///
/// 生命周期由 `AppState` 管理。终端视图**由本对象长期持有**，视图层只是把它摆上去，
/// 所以切换 tab 不会销毁视图、不会杀掉 PTY。
///
/// 线程：`LocalProcess` 默认把回调投递到主队列，因此下面所有代理方法都在主线程执行，
/// `@Published` 的更新是安全的。
final class SSHSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {

    enum State: Equatable {
        case connecting
        case connected
        /// 正常结束（远端 exit / 网络断开），带 ssh 退出码。
        case disconnected(exitCode: Int32?)
        /// 明确失败，带人话原因。
        case failed(reason: String)

        var isLive: Bool {
            switch self {
            case .connecting, .connected: return true
            case .disconnected, .failed: return false
            }
        }

        var label: String {
            switch self {
            case .connecting: return "连接中"
            case .connected: return "已连接"
            case .disconnected: return "已断开"
            case .failed(let reason): return reason
            }
        }
    }

    // MARK: - 身份

    let id = UUID()
    let config: HostConfig
    private let password: String

    /// 这条连接的 ControlMaster socket。
    ///
    /// 文件面板的 sftp 靠它复用**这条已经认证过的连接**（见 `SFTPCommandBuilder.makePlan`），
    /// 所以列目录和传文件都不用再认证一次，密码只在下面 `launch()` 里出现那一次。
    /// 一个会话一份，不跟同主机的其他分栏共享 —— 共享的话当 master 的那栏一断，其余的会一起掉。
    let controlPath = MoontermPaths.newControlSocketPath()

    // MARK: - 对外状态

    @Published private(set) var state: State = .connecting
    /// 远端通过 OSC 设置的标题（用于窗口标题栏）。
    @Published private(set) var remoteTitle: String?

    /// 远端 shell 当前所在目录，文件面板用它「定位到当前目录」。nil = 还没探到。
    ///
    /// 只能靠远端主动吐出来的东西猜（OSC 7 优先，没有就解析 xterm 标题），
    /// 判定逻辑在 `RemoteCwdParser` 里，有单测。`home` 这一路要等文件面板问出家目录才补上，
    /// 所以这里存的是**原始线索**，展开成绝对路径是 `remoteDirectory(home:)` 的事。
    @Published private(set) var osc7Directory: String?

    /// 已经连上、并且 ControlMaster socket 应该就位了 —— 文件面板据此决定要不要发 sftp。
    var isMultiplexReady: Bool { state == .connected }

    /// 结合家目录算出的当前目录。两条线索都不可用时 nil。
    func remoteDirectory(home: String?) -> String? {
        RemoteCwdParser.resolve(osc7: osc7Directory, title: remoteTitle, home: home)
    }

    let terminalView: SSHTerminalView

    // MARK: - 内部

    private let monitor: SSHOutputMonitor
    private var askpass: AskpassBridge?
    private var hasLaunchedOnce = false
    private var wantsRelaunchAfterExit = false
    private var pendingWorkItems: [DispatchWorkItem] = []

    /// 密码兜底注入的时间窗口：连上以后就关掉，免得把 SSH 密码灌给远端的 sudo 提示。
    private static let passwordInjectionWindow: TimeInterval = 20
    /// 临时密码文件的存活时间上限。
    private static let secretLifetime: TimeInterval = 40

    init(config: HostConfig, password: String, fontSize: CGFloat) {
        self.config = config
        self.password = password
        self.monitor = SSHOutputMonitor(password: password)
        self.terminalView = SSHTerminalView(frame: .zero)
        super.init()

        terminalView.processDelegate = self
        terminalView.observer = self
        terminalView.font = AppFont.terminalFont(size: fontSize)

        // 等视图拿到真实尺寸再开进程，这样远端一开始就是正确的行列数。
        terminalView.onReadyForProcess = { [weak self] in
            self?.launchIfNeeded()
        }
    }

    /// 把键盘焦点交给这个终端（切 tab、⌥⌘方向键切分栏时用）。
    func takeKeyboardFocus() {
        guard let window = terminalView.window else { return }
        window.makeFirstResponder(terminalView)
    }

    // MARK: - 启停

    /// 首次启动。视图尺寸就绪时自动调用；也可由外部兜底调用。
    func launchIfNeeded() {
        guard !hasLaunchedOnce else { return }
        hasLaunchedOnce = true
        launch()
    }

    /// 重连。进程还在跑就先终止，等它真的退出再拉起来（`LocalProcess` 在 running 时会忽略启动请求）。
    func reconnect() {
        if terminalView.process.running {
            wantsRelaunchAfterExit = true
            terminalView.terminate()
        } else {
            terminalView.feed(text: "\u{1b}c")  // RIS：清屏并复位终端
            launch()
        }
    }

    /// 关 tab 时调用：终止进程并清掉临时密码文件。
    func close() {
        wantsRelaunchAfterExit = false
        cancelPendingWork()
        if terminalView.process.running {
            terminalView.terminate()
        }
        askpass?.cleanup()
        askpass = nil
        // ssh 退出时自己会删 socket；这里再删一次是给「被 SIGKILL 掉」之类的情况兜底，
        // 免得临时目录里越积越多。
        unlink(controlPath)
    }

    private func launch() {
        hasLaunchedOnce = true
        cancelPendingWork()
        monitor.reset()
        state = .connecting

        var askpassPair: (helperPath: String, secretPath: String)?
        if !password.isEmpty {
            if let helperPath = AskpassBridge.locateHelper() {
                do {
                    let bridge = try AskpassBridge(password: password)
                    askpass = bridge
                    askpassPair = (helperPath, bridge.secretPath)
                } catch {
                    notice("准备密码失败（\(error.localizedDescription)），改为在终端提示时填入")
                }
            } else {
                notice("未找到 \(AskpassBridge.helperExecutableName) 助手，改为在终端提示时填入密码")
            }
        }

        let plan = SSHCommandBuilder.makePlan(
            config: config,
            askpass: askpassPair,
            controlPath: controlPath,
            baseEnvironment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
        )

        notice("正在连接 \(config.endpointDescription) …")
        terminalView.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: plan.environment
        )

        monitor.passwordInjectionEnabled = !password.isEmpty
        schedule(after: Self.passwordInjectionWindow) { [weak self] in
            self?.monitor.passwordInjectionEnabled = false
        }
        schedule(after: Self.secretLifetime) { [weak self] in
            self?.askpass?.cleanup()
            self?.askpass = nil
        }
    }

    // MARK: - 外观

    func applyFontSize(_ size: CGFloat) {
        terminalView.font = AppFont.terminalFont(size: size)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // 父类已经把新尺寸通过 TIOCSWINSZ 同步给了 PTY，这里不需要额外动作。
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        remoteTitle = title.isEmpty ? nil : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7（`\e]7;file://host/path`）。远端配了才有 —— Linux 发行版默认都不发，
        // 所以文件面板还留了「解析 xterm 标题」那条兜底路径。
        osc7Directory = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        cancelPendingWork()
        askpass?.cleanup()
        askpass = nil

        let wasConnecting = (state == .connecting)

        if let reason = monitor.diagnostic {
            state = .failed(reason: reason)
            notice("连接结束：\(reason)")
        } else if wasConnecting {
            let suffix = exitCode.map { "（ssh 退出码 \($0)）" } ?? ""
            state = .failed(reason: "连接失败\(suffix)")
            notice("连接失败\(suffix)")
        } else {
            state = .disconnected(exitCode: exitCode)
            notice("连接已断开，按 ⌘R 重连")
        }

        if wantsRelaunchAfterExit {
            wantsRelaunchAfterExit = false
            // 等这一轮回调走完再拉起新进程，避免和 LocalProcess 的收尾逻辑打架。
            DispatchQueue.main.async { [weak self] in
                self?.terminalView.feed(text: "\u{1b}c")  // RIS：清屏并复位终端
                self?.launch()
            }
        }
    }

    // MARK: - 辅助

    /// 往终端里插一行 moonterm 自己的提示，和远端输出区分开。
    private func notice(_ text: String) {
        terminalView.feed(text: "\r\n\u{1b}[2m[moonterm] \(text)\u{1b}[0m\r\n")
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem(block: body)
        pendingWorkItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPendingWork() {
        pendingWorkItems.forEach { $0.cancel() }
        pendingWorkItems.removeAll()
    }
}

// MARK: - 原始输出观察

extension SSHSession: SSHTerminalViewObserver {

    func terminalView(_ view: SSHTerminalView, didReceiveOutput slice: ArraySlice<UInt8>) {
        if let injection = monitor.consume(slice) {
            // askpass 没生效（老版 ssh 或特殊的 keyboard-interactive 流程），
            // 退回到往 PTY 里写密码。只会发生一次。
            view.process.send(data: ArraySlice(Array(injection.utf8)))
        }

        guard state == .connecting else { return }
        if let reason = monitor.diagnostic {
            state = .failed(reason: reason)
        } else {
            state = .connected
        }
    }
}
