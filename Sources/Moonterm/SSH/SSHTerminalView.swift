import AppKit
import SwiftTerm

/// 观察 PTY 原始输出的钩子（用于密码兜底注入与失败归因）。
protocol SSHTerminalViewObserver: AnyObject {
    func terminalView(_ view: SSHTerminalView, didReceiveOutput slice: ArraySlice<UInt8>)
}

/// `LocalProcessTerminalView` 已经把 forkpty、PTY 读写、窗口大小同步（TIOCSWINSZ）、
/// VT/xterm 解析、滚动缓冲、选区与复制粘贴全做了。这里只加两件事：
///
/// - 把原始输出抄送给观察者
/// - 视图第一次拿到真实尺寸时回调，让会话在正确的行列数下启动 ssh
///   （否则远端 shell 会先以 80x25 启动再 reflow）
final class SSHTerminalView: LocalProcessTerminalView {

    weak var observer: SSHTerminalViewObserver?

    /// 只触发一次：视图第一次具备非零尺寸时。
    var onReadyForProcess: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        observer?.terminalView(self, didReceiveOutput: slice)
    }

    // MARK: - 尺寸就绪

    override func layout() {
        super.layout()
        notifyIfReady()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        notifyIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyIfReady()
    }

    private func notifyIfReady() {
        guard let callback = onReadyForProcess,
              bounds.width > 1,
              bounds.height > 1
        else { return }
        onReadyForProcess = nil
        callback()
    }
}
